// Chalk egress proxy: the only way out of a sandbox started with
// CHALK_EGRESS=allowlist. It runs in a container of its own, on the
// sandbox's private network and on Docker's default one, and forwards only
// to the hosts named in CHALK_EGRESS_HOSTS (see sandbox_egress_hosts in
// lib/sandbox.sh). HTTPS is tunnelled with CONNECT and never decrypted.
//
// A rule is HOST (ports 80 and 443), HOST:PORT, or .DOMAIN for a domain and
// every name under it. Each decision is one line on stdout:
//   2026-01-01T00:00:00.000Z allow api.anthropic.com:443
//   2026-01-01T00:00:00.000Z deny example.com:443
'use strict';

const http = require('http');
const net = require('net');

const rules = (process.env.CHALK_EGRESS_HOSTS || '')
  .split(/\s+/)
  .filter(Boolean)
  .map((rule) => {
    const colon = rule.lastIndexOf(':');
    const withPort = colon > 0 && /^\d+$/.test(rule.slice(colon + 1));
    return {
      name: (withPort ? rule.slice(0, colon) : rule).toLowerCase(),
      ports: withPort ? [Number(rule.slice(colon + 1))] : [80, 443],
    };
  });

function allowed(host, port) {
  const name = String(host).toLowerCase().replace(/\.$/, '');
  return rules.some(
    (rule) =>
      rule.ports.includes(port) &&
      (rule.name.startsWith('.')
        ? name === rule.name.slice(1) || name.endsWith(rule.name)
        : name === rule.name),
  );
}

function decide(host, port) {
  const ok = Number.isInteger(port) && Boolean(host) && allowed(host, port);
  console.log(`${new Date().toISOString()} ${ok ? 'allow' : 'deny'} ${host}:${port}`);
  return ok;
}

function refusal(host) {
  return `chalk egress: ${host} is not on this sandbox's allowlist; an engineer can add it to CHALK_EGRESS_ALLOW\n`;
}

// Plain HTTP through the proxy: the request line carries an absolute URL.
const server = http.createServer((request, response) => {
  let url;
  try {
    url = new URL(request.url);
  } catch {
    response.writeHead(400, { 'content-type': 'text/plain' });
    response.end('chalk egress: this is a proxy; it serves no pages\n');
    return;
  }
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const port = Number(url.port || 80);
  if (url.protocol !== 'http:' || !decide(host, port)) {
    response.writeHead(403, { 'content-type': 'text/plain' });
    response.end(refusal(host));
    return;
  }
  const headers = { ...request.headers };
  delete headers['proxy-connection'];
  delete headers['proxy-authorization'];
  const upstream = http.request(
    { host, port, method: request.method, path: url.pathname + url.search, headers },
    (answer) => {
      response.writeHead(answer.statusCode, answer.headers);
      answer.pipe(response);
    },
  );
  upstream.on('error', (error) => {
    if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain' });
    response.end(`chalk egress: ${error.message}\n`);
  });
  request.pipe(upstream);
});

// HTTPS, and anything else that tunnels: CONNECT host:port.
server.on('connect', (request, client, head) => {
  const colon = request.url.lastIndexOf(':');
  const host = request.url.slice(0, Math.max(colon, 0)).replace(/^\[|\]$/g, '');
  const port = Number(request.url.slice(colon + 1));
  client.on('error', () => {});
  if (colon < 1 || !decide(host, port)) {
    client.end(
      `HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n${refusal(host)}`,
    );
    return;
  }
  let open = false;
  const upstream = net.connect(port, host, () => {
    open = true;
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    upstream.write(head);
    upstream.pipe(client);
    client.pipe(upstream);
  });
  upstream.on('error', (error) => {
    if (open) client.destroy();
    else client.end(`HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\nchalk egress: ${error.message}\n`);
  });
  client.on('close', () => upstream.destroy());
});

server.listen(Number(process.env.CHALK_EGRESS_PORT || 3128), '0.0.0.0', () => {
  console.log(`${new Date().toISOString()} listening, ${rules.length} rule(s)`);
});
