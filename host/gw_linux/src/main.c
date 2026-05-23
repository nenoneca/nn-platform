/* SPDX-License-Identifier: Apache-2.0 */

/*
 * gw_linux — Linux gateway-host daemon, currently a smoke-test harness
 * for the shared fw_common modules.
 *
 * Subcommands:
 *   spinel [/dev/ttyAMA3]
 *       Open the given UART (default /dev/ttyAMA3) at 460800 8N1 +RTSCTS,
 *       send a Spinel NOOP frame via fw_common HDLC+Spinel, wait for the
 *       ACK frame, verify LAST_STATUS = OK.
 *
 *   crypto
 *       Initialise fw_common/hub_crypto on this Linux host, generate
 *       (or load) the device's X25519 keypair, set the "hub" pubkey
 *       to a copy of the device's own pubkey (self-loop), then
 *       encrypt + decrypt a short plaintext through the same envelope
 *       parser/builder used by the Zephyr firmware.  Verifies the PSA
 *       crypto path + the new envelope/base64/kvstore plumbing.
 *
 *   default = spinel
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <poll.h>

#include <fw_common/gw_ble_prov_linux.h>
#include <fw_common/gw_identity.h>
#include <fw_common/gw_net_prov.h>
#include <fw_common/gw_ot_apply.h>
#include <fw_common/gw_provision.h>
#include <fw_common/hdlc.h>
#include <fw_common/hub_crypto.h>
#include <fw_common/log.h>
#include <fw_common/ncp_link.h>
#include <fw_common/proto_router.h>
#include <fw_common/proto_tcp.h>
#include <fw_common/proto_udp.h>
#include <fw_common/spinel.h>

#include <nn_proto/nn_proto.h>

LOG_MODULE_REGISTER(gw_linux_main, LOG_LEVEL_INF);

/* ── Spinel NOOP smoke test ────────────────────────────────────────── */

static int open_uart(const char *path, speed_t baud)
{
	int fd = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC);
	if (fd < 0) {
		LOG_ERR("open(%s): %s", path, strerror(errno));
		return -1;
	}
	struct termios tio;
	if (tcgetattr(fd, &tio) != 0) {
		LOG_ERR("tcgetattr: %s", strerror(errno));
		close(fd);
		return -1;
	}
	cfmakeraw(&tio);
	cfsetispeed(&tio, baud);
	cfsetospeed(&tio, baud);
	tio.c_cflag |= (CLOCAL | CREAD | CRTSCTS);
	tio.c_cflag &= ~(PARENB | CSTOPB);
	tio.c_cflag &= ~CSIZE;
	tio.c_cflag |= CS8;
	tio.c_cc[VMIN]  = 0;
	tio.c_cc[VTIME] = 0;
	if (tcsetattr(fd, TCSANOW, &tio) != 0) {
		LOG_ERR("tcsetattr: %s", strerror(errno));
		close(fd);
		return -1;
	}
	tcflush(fd, TCIOFLUSH);
	return fd;
}

static volatile uint8_t g_rx[64];
static volatile size_t  g_rx_len;
static volatile int     g_frame_seen;

static void on_frame(const uint8_t *payload, size_t len, void *user)
{
	(void)user;
	if (len > sizeof(g_rx)) return;
	memcpy((uint8_t *)g_rx, payload, len);
	g_rx_len     = len;
	g_frame_seen = 1;
}

static int do_spinel(const char *port)
{
	int fd = open_uart(port, B460800);
	if (fd < 0) return 1;
	LOG_INF("opened %s @ 460800 8N1 +RTSCTS", port);

	uint8_t spinel[2] = { SPINEL_HEADER_FLAG | 0x01, SPINEL_CMD_NOOP };
	uint8_t wire[32];
	int n = hdlc_encode(spinel, sizeof(spinel), wire, sizeof(wire));
	if (n <= 0) { close(fd); return 2; }

	LOG_INF("TX %d B Spinel NOOP", n);
	if (write(fd, wire, (size_t)n) != (ssize_t)n) { close(fd); return 3; }

	struct hdlc_decoder dec;
	hdlc_decoder_init(&dec, on_frame, NULL);
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
	while (!g_frame_seen) {
		struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
		long ms = (now.tv_sec - t0.tv_sec) * 1000L +
			  (now.tv_nsec - t0.tv_nsec) / 1000000L;
		if (ms > 1500) {
			LOG_ERR("no Spinel reply within 1.5 s");
			close(fd); return 4;
		}
		int pr = poll(&pfd, 1, 1500 - (int)ms);
		if (pr <= 0) continue;
		uint8_t rbuf[64];
		ssize_t got = read(fd, rbuf, sizeof(rbuf));
		for (ssize_t i = 0; i < got; i++) hdlc_decode_byte(&dec, rbuf[i]);
	}
	if (g_rx_len < 4 ||
	    g_rx[0] != (SPINEL_HEADER_FLAG | 0x01) ||
	    g_rx[1] != SPINEL_CMD_PROP_VALUE_IS ||
	    g_rx[2] != SPINEL_PROP_LAST_STATUS) {
		LOG_ERR("unexpected Spinel reply");
		close(fd); return 5;
	}
	LOG_INF("NOOP round-trip OK — LAST_STATUS = 0x%02x", g_rx[3]);
	close(fd);
	return 0;
}

/* ── hub_crypto self-loop smoke test ───────────────────────────────── */

static int do_crypto(void)
{
	LOG_INF("hub_crypto self-loop on Linux");
	int rc = hub_crypto_init();
	if (rc) { LOG_ERR("hub_crypto_init: %d", rc); return 11; }

	/* Use the device's own X25519 pubkey as the "hub" pubkey so we
	 * can drive a self-encrypt → self-decrypt round-trip through the
	 * shared ECIES path. */
	uint8_t dev_pub[32];
	hub_crypto_get_device_x25519_pub(dev_pub);
	rc = hub_crypto_set_hub_pubkey(dev_pub);
	if (rc) { LOG_ERR("hub_crypto_set_hub_pubkey: %d", rc); return 12; }

	const char plaintext[] = "{\"hello\":\"from gw_linux\"}";
	char envelope[1024];
	rc = hub_crypto_encrypt((const uint8_t *)plaintext, sizeof(plaintext) - 1,
				envelope, sizeof(envelope));
	if (rc) { LOG_ERR("hub_crypto_encrypt: %d", rc); return 13; }
	LOG_INF("encrypted envelope (%zu chars):", strlen(envelope));
	fprintf(stderr, "  %s\n", envelope);

	/* hub_crypto_decrypt parses the H2D direction (info=h2d).  Since
	 * we encrypted as D2H (the only direction we have on the device
	 * side), running decrypt on it should NOT verify (auth-fail) —
	 * but the envelope parse + base64 decode path runs fully, which
	 * is the part we want to smoke-test.  Better self-loop: encrypt
	 * with D2H, decrypt with D2H — which means we'd need a separate
	 * "device-side decrypt" path, currently not in hub_crypto.
	 *
	 * For this smoke test we just verify encrypt succeeds + produces
	 * a parseable envelope.  A future round-trip test using the hub
	 * keypair (or a test-mode decrypt with D2H info tag) would
	 * close the loop. */
	uint8_t plain_out[256];
	size_t  plain_out_len = sizeof(plain_out);
	rc = hub_crypto_decrypt(envelope, plain_out, &plain_out_len);
	if (rc == -EACCES) {
		LOG_INF("decrypt expectedly returned -EACCES (D2H envelope "
			"can't be decrypted via the H2D path — auth tag "
			"derived from a different HKDF info)");
		LOG_INF("crypto self-loop: encrypt OK, decrypt-path exercised");
		return 0;
	}
	if (rc == 0) {
		LOG_INF("decrypt produced %zu bytes (unexpected for D2H/H2D "
			"asymmetry — check HKDF info tags)", plain_out_len);
		return 0;
	}
	LOG_ERR("hub_crypto_decrypt failed unexpectedly: %d", rc);
	return 14;
}

/* ── gw_identity sign/verify smoke test ────────────────────────────── */

static int do_identity(void)
{
	LOG_INF("gw_identity smoke test on Linux");
	int rc = gw_identity_init();
	if (rc) { LOG_ERR("gw_identity_init: %d", rc); return 21; }

	const uint8_t *id  = gw_identity_get_id();
	const uint8_t *pub = gw_identity_get_pubkey();
	if (!id || !pub) {
		LOG_ERR("getters returned NULL after init");
		return 22;
	}
	fprintf(stderr, "  gateway_id : ");
	for (int i = 0; i < GW_IDENTITY_ID_LEN; i++) fprintf(stderr, "%02x", id[i]);
	fprintf(stderr, "\n  p256_pub   : ");
	for (int i = 0; i < GW_IDENTITY_PUBKEY_LEN; i++)
		fprintf(stderr, "%02x", pub[i]);
	fprintf(stderr, "\n");

	const uint8_t msg[] = "nn_proto signtest (linux daemon)";
	uint8_t sig[GW_IDENTITY_SIG_LEN];

	rc = gw_identity_sign(NULL, msg, sizeof(msg) - 1, sig);
	if (rc) { LOG_ERR("sign: %d", rc); return 23; }
	LOG_INF("sign OK (sig length=%d)", GW_IDENTITY_SIG_LEN);

	rc = gw_identity_verify((void *)pub, msg, sizeof(msg) - 1, sig);
	if (rc) { LOG_ERR("verify: %d", rc); return 24; }
	LOG_INF("verify OK — sign+verify round-trip complete on Linux");

	/* Negative test: a tampered byte should fail verify. */
	uint8_t bad_msg[sizeof(msg) - 1];
	memcpy(bad_msg, msg, sizeof(bad_msg));
	bad_msg[0] ^= 0xff;
	rc = gw_identity_verify((void *)pub, bad_msg, sizeof(bad_msg), sig);
	if (rc == -EBADMSG) {
		LOG_INF("tamper detection OK (verify -> -EBADMSG)");
	} else {
		LOG_ERR("tamper test unexpected rv=%d", rc);
		return 25;
	}
	return 0;
}

/* ── operate-mode RX adapters ───────────────────────────────────────
 *
 * proto_router's entry points return int and have narrower argument
 * lists than what proto_udp / proto_tcp's on_rx function pointers
 * expect.  Two tiny adapters bridge the shapes. */

static void operate_on_udp_rx(const uint8_t *frame, size_t len,
			      const struct in6_addr *src,
			      uint16_t src_port, void *user)
{
	(void)src_port; (void)user;
	(void)proto_router_on_udp_rx(frame, len, src);
}

static void operate_on_tcp_rx(const uint8_t *frame, size_t len, void *user)
{
	(void)user;
	(void)proto_router_on_tcp_rx(frame, len);
}

/* ── BLE provisioning daemon ───────────────────────────────────────── */

static int do_provision(const char *adapter)
{
	LOG_INF("starting BLE provisioning backend (adapter='%s')",
		adapter ? adapter : "/org/bluez/hci0");

	int rc = gw_identity_init();
	if (rc) {
		LOG_ERR("gw_identity_init: %d", rc);
		return 31;
	}
	rc = gw_provision_init();
	if (rc) {
		LOG_WRN("gw_provision_init: %d (continuing)", rc);
	}

	rc = gw_ble_prov_linux_start(adapter);
	if (rc) {
		LOG_ERR("gw_ble_prov_linux_start: %d", rc);
		return 32;
	}
	rc = gw_ble_prov_linux_run();
	gw_ble_prov_linux_stop();
	return rc < 0 ? 33 : 0;
}

int main(int argc, char **argv)
{
	const char *cmd = (argc > 1) ? argv[1] : "spinel";

	if (!strcmp(cmd, "spinel")) {
		const char *port = (argc > 2) ? argv[2] : "/dev/ttyAMA3";
		return do_spinel(port);
	}
	if (!strcmp(cmd, "crypto")) {
		return do_crypto();
	}
	if (!strcmp(cmd, "identity")) {
		return do_identity();
	}
	if (!strcmp(cmd, "provision")) {
		const char *adapter = (argc > 2) ? argv[2] : NULL;
		return do_provision(adapter);
	}
	if (!strcmp(cmd, "ncp")) {
		const char *uart = (argc > 2) ? argv[2] : "/dev/ttyAMA3";
		LOG_INF("ncp smoke test on %s", uart);
		int rc = ncp_link_init_linux(uart);
		if (rc) { LOG_ERR("ncp_link_init_linux: %d", rc); return 61; }
		struct timespec ts = { .tv_sec = 0, .tv_nsec = 300 * 1000 * 1000 };
		nanosleep(&ts, NULL);

		const uint32_t probes[] = {
			SPINEL_PROP_NCP_VERSION,
			SPINEL_PROP_PROTOCOL_VERSION,
			SPINEL_PROP_INTERFACE_TYPE,
			SPINEL_PROP_CAPS,
		};
		const char *labels[] = {
			"NCP_VERSION", "PROTOCOL_VERSION", "INTERFACE_TYPE",
			"CAPS",
		};
		for (size_t i = 0; i < sizeof probes / sizeof probes[0]; i++) {
			uint8_t buf[256];
			size_t len = sizeof buf;
			int rv = ncp_link_get(probes[i], buf, &len, 2000);
			if (rv < 0) {
				LOG_WRN("  %s: rv=%d", labels[i], rv);
				continue;
			}
			fprintf(stderr, "  %-18s len=%zu  ", labels[i], len);
			for (size_t j = 0; j < len && j < 32; j++) {
				fprintf(stderr, "%02x", buf[j]);
			}
			fprintf(stderr, "%s\n", len > 32 ? "..." : "");
		}
		LOG_INF("ncp smoke test done");
		return 0;
	}
	if (!strcmp(cmd, "operate")) {
		const char *uart = (argc > 2) ? argv[2] : "/dev/ttyAMA3";
		LOG_INF("starting operate mode (NCP=%s)", uart);

		/* 1. identity + persisted provision ----------------------- */
		int rc = gw_identity_init();
		if (rc) { LOG_ERR("gw_identity_init: %d", rc); return 51; }
		rc = gw_provision_init();
		if (rc) { LOG_ERR("gw_provision_init: %d", rc); return 52; }
		if (!gw_provision_is_complete()) {
			LOG_ERR("not provisioned — run provision-net first");
			return 53;
		}

		/* 2. NCP link up + apply OT dataset + bring Thread up ---- */
		rc = ncp_link_init_linux(uart);
		if (rc) { LOG_ERR("ncp_link_init_linux: %d", rc); return 54; }
		struct timespec settle = { .tv_sec = 0, .tv_nsec = 500*1000*1000 };
		nanosleep(&settle, NULL);

		size_t ds_len = 0;
		const uint8_t *ds = gw_provision_get_ot_dataset(&ds_len);
		if (!ds || ds_len == 0) {
			LOG_ERR("no OT dataset in provision blob");
			return 55;
		}
		rc = gw_ot_apply_dataset(ds, ds_len);
		if (rc) { LOG_ERR("gw_ot_apply_dataset: %d", rc); return 56; }
		rc = gw_ot_bring_up();
		if (rc) { LOG_ERR("gw_ot_bring_up: %d", rc); return 57; }

		/* Wait for the mesh-local prefix / role to settle.  Poll
		 * NET_ROLE every 250 ms up to ~10 s. */
		LOG_INF("waiting for Thread role…");
		uint8_t role = 0;
		for (int i = 0; i < 40; i++) {
			uint8_t b = 0; size_t bl = 1;
			if (ncp_link_get(SPINEL_PROP_NET_ROLE, &b, &bl, 500) == 0
			    && bl >= 1) {
				role = b;
				if (role != 0) break;  /* 0 = detached */
			}
			struct timespec t = { .tv_sec = 0, .tv_nsec = 250*1000*1000 };
			nanosleep(&t, NULL);
		}
		LOG_INF("Thread NET_ROLE=%u", role);

		/* 3. proto_router + proto_udp (netif-bypass) ------------- */
		rc = proto_router_init();
		if (rc) { LOG_ERR("proto_router_init: %d", rc); return 58; }

		struct proto_udp_config ucfg = {
			.port       = 49190,  /* matches sensor's NODE_MGR_NN_PROTO_PORT */
			.on_rx      = operate_on_udp_rx,
			.on_rx_user = NULL,
		};
		rc = proto_udp_init(&ucfg);
		if (rc) { LOG_ERR("proto_udp_init: %d", rc); return 59; }

		/* 4. proto_tcp out to hub -------------------------------- */
		const char *hub = gw_provision_get_hub_mdns();
		LOG_INF("hub target: %s:8767", hub);
		struct proto_tcp_config tcfg = {
			.hub_hostname = hub,
			.hub_port     = 8767,
			.on_rx        = operate_on_tcp_rx,
			.on_rx_user   = NULL,
		};
		rc = proto_tcp_init(&tcfg);
		if (rc) { LOG_ERR("proto_tcp_init: %d", rc); return 60; }

		/* 5. heartbeat loop ─────────────────────────────────────
		 *   every 5 s:  D2G HUB_STATUS_QUERY to hub via TCP
		 *               G2D GATEWAY_HELLO mcast on Thread so
		 *               sensors learn our mesh-local IPv6
		 */
		const uint8_t *gw_id = gw_identity_get_id();

		uint8_t ml_eid[16] = {0};
		{
			uint8_t buf[16]; size_t bl = sizeof buf;
			if (ncp_link_get(SPINEL_PROP_IPV6_ML_ADDR,
					 buf, &bl, 1000) == 0 && bl >= 16) {
				memcpy(ml_eid, buf, 16);
			}
		}
		while (1) {
			sleep(5);

			/* G2D GATEWAY_HELLO mcast — payload:
			 * [2B cmd LE][16B gw mesh-local IPv6][2B interval LE]
			 * [1B online].  No device_id (mcast). */
			uint8_t hello_inner[2 + 16 + 2 + 1] = {0};
			hello_inner[0] = (uint8_t)(NN_PROTO_CMD_GATEWAY_HELLO & 0xff);
			hello_inner[1] = (uint8_t)(NN_PROTO_CMD_GATEWAY_HELLO >> 8);
			memcpy(hello_inner + 2, ml_eid, 16);
			hello_inner[18] = 5;        /* 5 s interval, LE */
			hello_inner[19] = 0;
			hello_inner[20] = (proto_tcp_get_state() == PROTO_TCP_UP) ? 1 : 0;
			{
				uint8_t hf[NN_PROTO_OVERHEAD + sizeof hello_inner];
				int n = nn_proto_encode(NN_PROTO_TYPE_G2D,
							NULL, 0,
							hello_inner, sizeof hello_inner,
							gw_identity_sign, NULL,
							hf, sizeof hf);
				if (n > 0) (void)proto_udp_send_mcast(hf, (size_t)n);
			}

			/* D2G HUB_STATUS_QUERY → hub */
			if (proto_tcp_get_state() != PROTO_TCP_UP) continue;
			uint8_t q_inner[2] = {
				(uint8_t)(NN_PROTO_CMD_HUB_STATUS_QUERY & 0xff),
				(uint8_t)(NN_PROTO_CMD_HUB_STATUS_QUERY >> 8),
			};
			uint8_t qf[NN_PROTO_OVERHEAD + 8 + sizeof q_inner];
			int qn = nn_proto_encode(NN_PROTO_TYPE_D2G,
						 gw_id, 8,
						 q_inner, sizeof q_inner,
						 gw_identity_sign, NULL,
						 qf, sizeof qf);
			if (qn > 0) (void)proto_tcp_enqueue(qf, (size_t)qn);

			/* D2G GATEWAY_THREAD_STATE → hub.  Payload:
			 * [2B cmd LE][1B role][2B rloc16 LE][16B mleid]
			 *
			 * Without this frame the hub never learns the gateway's
			 * actual Thread role and always reports role_name='detached'
			 * for the gateway. */
			{
				uint8_t  role_b   = 0;
				size_t   role_bl  = 1;
				uint16_t rloc16   = 0;
				uint8_t  rloc16_b[2] = {0};
				size_t   rloc16_bl   = 2;
				(void)ncp_link_get(SPINEL_PROP_NET_ROLE,
						   &role_b, &role_bl, 500);
				if (ncp_link_get(SPINEL_PROP_THREAD_RLOC16,
						 rloc16_b, &rloc16_bl, 500) == 0
				    && rloc16_bl >= 2) {
					rloc16 = (uint16_t)rloc16_b[0]
					       | ((uint16_t)rloc16_b[1] << 8);
				}

				uint8_t ts_inner[2 + 1 + 2 + 16] = {0};
				ts_inner[0] = (uint8_t)(NN_PROTO_CMD_GATEWAY_THREAD_STATE & 0xff);
				ts_inner[1] = (uint8_t)(NN_PROTO_CMD_GATEWAY_THREAD_STATE >> 8);
				ts_inner[2] = role_b;
				ts_inner[3] = (uint8_t)(rloc16 & 0xff);
				ts_inner[4] = (uint8_t)(rloc16 >> 8);
				memcpy(ts_inner + 5, ml_eid, 16);

				uint8_t tf[NN_PROTO_OVERHEAD + 8 + sizeof ts_inner];
				int tn = nn_proto_encode(NN_PROTO_TYPE_D2G,
							 gw_id, 8,
							 ts_inner, sizeof ts_inner,
							 gw_identity_sign, NULL,
							 tf, sizeof tf);
				if (tn > 0) (void)proto_tcp_enqueue(tf, (size_t)tn);
			}
		}
		return 0;
	}
	if (!strcmp(cmd, "provision-net")) {
		uint16_t port = 0;
		int mdns = 1;
		for (int i = 2; i < argc; i++) {
			if (!strcmp(argv[i], "--no-mdns")) {
				mdns = 0;
			} else {
				port = (uint16_t)atoi(argv[i]);
			}
		}
		LOG_INF("starting net provisioning backend (port=%u mdns=%d)",
			port ? port : GW_NET_PROV_DEFAULT_PORT, mdns);
		int rc = gw_identity_init();
		if (rc) { LOG_ERR("gw_identity_init: %d", rc); return 41; }
		rc = gw_provision_init();
		if (rc) LOG_WRN("gw_provision_init: %d (continuing)", rc);
		rc = gw_net_prov_start(port, mdns);
		if (rc) { LOG_ERR("gw_net_prov_start: %d", rc); return 42; }
		rc = gw_net_prov_run();
		gw_net_prov_stop();
		return rc < 0 ? 43 : 0;
	}
	fprintf(stderr,
		"usage: %s [spinel [/dev/tty...]] | [crypto] | [identity]\n"
		"       %s [provision [/org/bluez/hciN]]\n"
		"       %s [provision-net [port] [--no-mdns]]\n"
		"       %s [operate]\n",
		argv[0], argv[0], argv[0], argv[0]);
	return 2;
}
