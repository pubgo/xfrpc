// SPDX-License-Identifier: GPL-3.0-only

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "third_party/tomlc99/toml.h"
#include "config.h"
#include "client.h"
#include "debug.h"

static char *join_toml_string_array(const toml_array_t *arr)
{
	if (!arr) {
		return NULL;
	}

	int count = toml_array_nelem(arr);
	if (count <= 0) {
		return NULL;
	}

	size_t cap = 64;
	size_t len = 0;
	char *out = calloc(1, cap);
	if (!out) {
		return NULL;
	}

	for (int i = 0; i < count; i++) {
		toml_datum_t item = toml_string_at(arr, i);
		if (!item.ok || !item.u.s) {
			continue;
		}

		size_t item_len = strlen(item.u.s);
		if (len + item_len + 2 > cap) {
			cap = (len + item_len + 2) * 2;
			char *grown = realloc(out, cap);
			if (!grown) {
				free(out);
				free(item.u.s);
				return NULL;
			}
			out = grown;
		}

		if (len > 0) {
			out[len++] = ',';
		}
		memcpy(out + len, item.u.s, item_len);
		len += item_len;
		out[len] = '\0';
		free(item.u.s);
	}

	return out;
}

static void copy_toml_string(struct common_conf *config, const char *field, const toml_table_t *tab, const char *key)
{
	toml_datum_t value = toml_string_in(tab, key);
	if (!value.ok || !value.u.s) {
		return;
	}
	config_set_common_field(config, field, value.u.s);
	free(value.u.s);
}

static void apply_toml_bool_field(struct common_conf *config, const char *field, const toml_table_t *tab, const char *key)
{
	toml_datum_t value = toml_bool_in(tab, key);
	if (!value.ok) {
		return;
	}
	config_set_common_field(config, field, value.u.b ? "1" : "0");
}

static void apply_toml_int_field(struct common_conf *config, const char *field, const toml_table_t *tab, const char *key)
{
	toml_datum_t value = toml_int_in(tab, key);
	if (!value.ok) {
		return;
	}
	char buf[32];
	snprintf(buf, sizeof(buf), "%lld", (long long)value.u.i);
	config_set_common_field(config, field, buf);
}

static void apply_auth_additional_scopes(struct common_conf *config, const toml_table_t *auth)
{
	toml_array_t *scopes = toml_array_in(auth, "additionalScopes");
	if (!scopes) {
		return;
	}

	int count = toml_array_nelem(scopes);
	for (int i = 0; i < count; i++) {
		toml_datum_t item = toml_string_at(scopes, i);
		if (!item.ok || !item.u.s) {
			continue;
		}
		if (strcmp(item.u.s, "HeartBeats") == 0) {
			config->auth_scope_heartbeats = 1;
		} else if (strcmp(item.u.s, "NewWorkConns") == 0) {
			config->auth_scope_new_work_conns = 1;
		}
		free(item.u.s);
	}
}

static void load_toml_common(struct common_conf *config, const toml_table_t *root)
{
	copy_toml_string(config, "user", root, "user");
	copy_toml_string(config, "server_addr", root, "serverAddr");
	apply_toml_int_field(config, "server_port", root, "serverPort");
	copy_toml_string(config, "auth_token", root, "token");

	toml_table_t *auth = toml_table_in(root, "auth");
	if (auth) {
		copy_toml_string(config, "auth_method", auth, "method");
		copy_toml_string(config, "auth_token", auth, "token");
		apply_auth_additional_scopes(config, auth);
	}

	toml_table_t *transport = toml_table_in(root, "transport");
	if (transport) {
		apply_toml_int_field(config, "heartbeat_interval", transport, "heartbeatInterval");
		apply_toml_int_field(config, "heartbeat_timeout", transport, "heartbeatTimeout");
		apply_toml_bool_field(config, "tcp_mux", transport, "tcpMux");

		toml_table_t *tls = toml_table_in(transport, "tls");
		if (tls) {
			apply_toml_bool_field(config, "tls_enable", tls, "enable");
			copy_toml_string(config, "tls_cert_file", tls, "certFile");
			copy_toml_string(config, "tls_key_file", tls, "keyFile");
			copy_toml_string(config, "tls_trusted_ca_file", tls, "trustedCaFile");
			copy_toml_string(config, "tls_server_name", tls, "serverName");
		}
	}
}

static void apply_proxy_string(struct proxy_service *ps, const char *ini_key, const toml_table_t *tab, const char *toml_key)
{
	toml_datum_t value = toml_string_in(tab, toml_key);
	if (!value.ok || !value.u.s) {
		return;
	}
	config_set_proxy_field(ps, ini_key, value.u.s);
	free(value.u.s);
}

static void apply_proxy_bool(struct proxy_service *ps, const char *ini_key, const toml_table_t *tab, const char *toml_key)
{
	toml_datum_t value = toml_bool_in(tab, toml_key);
	if (!value.ok) {
		return;
	}
	config_set_proxy_field(ps, ini_key, value.u.b ? "true" : "false");
}

static void apply_proxy_int(struct proxy_service *ps, const char *ini_key, const toml_table_t *tab, const char *toml_key)
{
	toml_datum_t value = toml_int_in(tab, toml_key);
	if (!value.ok) {
		return;
	}
	char buf[32];
	snprintf(buf, sizeof(buf), "%lld", (long long)value.u.i);
	config_set_proxy_field(ps, ini_key, buf);
}

static void load_toml_proxy(struct proxy_service *ps, const toml_table_t *proxy)
{
	apply_proxy_string(ps, "type", proxy, "type");
	apply_proxy_string(ps, "local_ip", proxy, "localIP");
	apply_proxy_string(ps, "bind_addr", proxy, "bindAddr");
	apply_proxy_int(ps, "local_port", proxy, "localPort");
	apply_proxy_int(ps, "remote_port", proxy, "remotePort");
	apply_proxy_int(ps, "remote_data_port", proxy, "remoteDataPort");
	apply_proxy_bool(ps, "use_encryption", proxy, "useEncryption");
	apply_proxy_bool(ps, "use_compression", proxy, "useCompression");
	apply_proxy_string(ps, "subdomain", proxy, "subdomain");
	apply_proxy_string(ps, "host_header_rewrite", proxy, "hostHeaderRewrite");
	apply_proxy_string(ps, "group", proxy, "group");
	apply_proxy_string(ps, "group_key", proxy, "groupKey");
	apply_proxy_string(ps, "plugin", proxy, "plugin");
	apply_proxy_string(ps, "plugin_user", proxy, "pluginUser");
	apply_proxy_string(ps, "plugin_pwd", proxy, "pluginPwd");
	apply_proxy_string(ps, "root_dir", proxy, "rootDir");
	apply_proxy_string(ps, "multiplexer", proxy, "multiplexer");
	apply_proxy_string(ps, "route_by_http_user", proxy, "routeByHTTPUser");
	apply_proxy_string(ps, "sk", proxy, "secretKey");
	apply_proxy_string(ps, "sk", proxy, "sk");

	toml_array_t *locations = toml_array_in(proxy, "locations");
	char *joined_locations = join_toml_string_array(locations);
	if (joined_locations) {
		config_set_proxy_field(ps, "locations", joined_locations);
		free(joined_locations);
	}

	toml_array_t *custom_domains = toml_array_in(proxy, "customDomains");
	char *joined_domains = join_toml_string_array(custom_domains);
	if (joined_domains) {
		config_set_proxy_field(ps, "custom_domains", joined_domains);
		free(joined_domains);
	}

	toml_array_t *allow_users = toml_array_in(proxy, "allowUsers");
	char *joined_users = join_toml_string_array(allow_users);
	if (joined_users) {
		config_set_proxy_field(ps, "allow_users", joined_users);
		free(joined_users);
	}

	toml_table_t *transport = toml_table_in(proxy, "transport");
	if (transport) {
		apply_proxy_bool(ps, "use_compression", transport, "useCompression");
		apply_proxy_bool(ps, "use_encryption", transport, "useEncryption");
	}

	toml_table_t *request_headers = toml_table_in(proxy, "requestHeaders");
	if (request_headers) {
		toml_table_t *set = toml_table_in(request_headers, "set");
		if (set) {
			toml_datum_t referer = toml_string_in(set, "Referer");
			if (referer.ok && referer.u.s) {
				config_set_proxy_field(ps, "http_referer", referer.u.s);
				free(referer.u.s);
			}
		}
	}
}

static void load_toml_proxies(const toml_table_t *root)
{
	toml_array_t *proxies = toml_array_in(root, "proxies");
	if (!proxies) {
		debug(LOG_ERR, "TOML config missing [[proxies]]");
		exit(0);
	}

	int count = toml_array_nelem(proxies);
	if (count <= 0) {
		debug(LOG_ERR, "TOML config requires at least one proxy");
		exit(0);
	}

	for (int i = 0; i < count; i++) {
		toml_table_t *proxy = toml_table_at(proxies, i);
		if (!proxy) {
			continue;
		}

		toml_datum_t name = toml_string_in(proxy, "name");
		if (!name.ok || !name.u.s || !*name.u.s) {
			debug(LOG_ERR, "proxies[%d].name is required", i);
			free(name.u.s);
			exit(0);
		}

		struct proxy_service *ps = config_create_proxy(name.u.s);
		free(name.u.s);
		if (!ps) {
			debug(LOG_ERR, "Failed to create proxy service");
			exit(0);
		}

		load_toml_proxy(ps, proxy);
	}
}

int config_is_toml_path(const char *confile)
{
	if (!confile) {
		return 0;
	}

	size_t len = strlen(confile);
	if (len >= 5 && strcmp(confile + len - 5, ".toml") == 0) {
		return 1;
	}

	FILE *fp = fopen(confile, "r");
	if (!fp) {
		return 0;
	}

	int ch = EOF;
	while ((ch = fgetc(fp)) != EOF) {
		if (!isspace(ch)) {
			break;
		}
	}
	fclose(fp);

	return ch != '[';
}

void load_toml_config(const char *confile)
{
	struct common_conf *config = get_common_config();
	if (!config) {
		debug(LOG_ERR, "Common config is not initialized");
		exit(0);
	}

	char errbuf[256];
	FILE *fp = fopen(confile, "r");
	if (!fp) {
		debug(LOG_ERR, "Cannot open TOML config file: %s", confile);
		exit(0);
	}

	toml_table_t *root = toml_parse_file(fp, errbuf, sizeof(errbuf));
	fclose(fp);
	if (!root) {
		debug(LOG_ERR, "TOML parse failed: %s", errbuf);
		exit(0);
	}

	load_toml_common(config, root);
	load_toml_proxies(root);
	toml_free(root);
}
