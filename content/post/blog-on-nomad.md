+++
date = "2019-11-12"
title = "Running this Blog on Nomad"
enableInlineShortcodes = true
+++

In an attempt to consolidate my various personal projects, and to be efficient
about how much money I spend on VPS hosting, this blog is now running on my tiny
Nomad cluster. The ID for this allocation is:

Allocation ID: <strong>{{< alloc_id >}}</strong>

The components involved are:

1. [Nomad](https://www.nomadproject.io/)
2. [Consul](https://www.consul.io/)
3. [Vault](https://www.vaultproject.io/)
4. [Fabio](https://fabiolb.net/)
5. [multirootca](https://github.com/cloudflare/cfssl#the-multirootca)

The Nomad deployment guide recommends either [three or
five](https://www.nomadproject.io/docs/internals/consensus.html#deployment-table)
servers, but I'm not really running business-critical applications, so I
currently only have one server and one client node.

The `server` node is running one instance each of Consul, Nomad, and Vault, the
first two in server mode, with certificate authorities defined on a central
`support` server.

I save all of the config files in my
[infrastructure](https://git.sr.ht/~damien/infrastructure) repo. In particular,
these job files are responsible for running this blog:

1. [damienradtkecom.nomad](https://git.sr.ht/~damien/infrastructure/tree/master/jobs/damienradtkecom.nomad) (Hugo server)
2. [fabio.nomad](https://git.sr.ht/~damien/infrastructure/tree/master/jobs/fabio.nomad) (load balancer)
2. [acme-renewer.nomad](https://git.sr.ht/~damien/infrastructure/tree/master/jobs/acme-renewer.nomad) (certificate renewer periodic batch job)

### damienradtkecom

This job is responsible for running `hugo server` on the blog's source
directory. It specifies the service tag expected by Fabio so that requests to
`damienradtke.com` get routed to the blog server.

It also runs two instances and specifies an `update` block to ensure
zero-downtime deployments.

### fabio

This job runs the Fabio load balancer on a randomly-assigned port so that it
doesn't require root privileges, along with a custom, tiny Go program running as
root that routes traffic from port 443 to Fabio.

One upside to having only one client node is that the domain's A record can be
set to the client node's IP address, so traffic will properly make its way to
fabio. In case of a multi-client cluster, one node will need to be designated
the load balancer node, and the fabio job configured to always run on it.

### acme-renewer

This is a periodic batch job that uses `acme.sh` to renew the domain's SSL
certificate using a DNS challenge and the Linode API. The results are stored in
Vault's KV store, which Fabio is configured to read from to support HTTPS.
