// SPDX-License-Identifier: GPL-2.0-only
// BPI-R4: Node Dashboard exit — destroy LuCI session then redirect (U1a).
// Follow Host header so LAN IP changes (Setup Advanced) keep working.

function node_dashboard_url() {
	/* D2 (review 2026-10-11): back to the host the browser used — appliance
	   names or a private IPv4 literal (all in the leaf certificate); anything
	   else (LuCI on :8443 has no nginx Host allowlist) → rnode.local. */
	let h = lc(split(http.getenv('HTTP_HOST') || '', ':')[0] || '');
	if (match(h, /^(rnode\.local|rnode-[0-9a-f]{4}\.local|node-router|knots-router)$/) ||
	    match(h, /^(10|127)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/) ||
	    match(h, /^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$/) ||
	    match(h, /^172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}$/))
		return `https://${h}/`;
	return 'https://rnode.local/';
}

return {
	action_exit: function() {
		const dash = node_dashboard_url();
		const url = dispatcher.build_url();

		if (ctx.authsession) {
			ubus.call('session', 'destroy', { ubus_rpc_session: ctx.authsession });

			if (http.getenv('HTTPS') == 'on')
				http.header('Set-Cookie',
					`sysauth_https=; expires=Thu, 01 Jan 1970 01:00:00 GMT; path=${url}`);
			else
				http.header('Set-Cookie',
					`sysauth_http=; expires=Thu, 01 Jan 1970 01:00:00 GMT; path=${url}`);
		}

		http.redirect(dash);
	}
};
