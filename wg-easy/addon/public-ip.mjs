// Prints this network's public IPv4 address, or exits 1.
//
// Used only on the very first start when the `host` option is empty, so that
// the add-on works without any configuration (WG-Easy's own setup wizard does
// the same lookup). The value can be changed later in the WG-Easy web UI or
// pinned with the `host` option, e.g. to a dynamic-DNS name.
const SOURCES = ["https://api.ipify.org", "https://ipv4.icanhazip.com", "https://ifconfig.me/ip"];
const IPV4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;

for (const url of SOURCES) {
    try {
        const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
        const ip = (await res.text()).trim();
        if (res.ok && IPV4.test(ip)) {
            console.log(ip);
            process.exit(0);
        }
    } catch {
        /* try the next source */
    }
}
process.exit(1);
