+++
date = "2019-06-24"
title = "Overengineering This Blog"
draft = true
+++

Lately, I've taken quite an interest in a couple things: the Hashicorp stack,
and building robust platforms on top of VPS providers, rather than a cloud like
AWS. As a result, this very blog, a Hugo-powered static site which used to run
on a single node via nginx, is now running on a
Nomad cluster deployed with
Linode, so while it is still on just a single
node as of this writing, I can now needlessly scale this site to my heart's
content should I ever feel the urge to do so.

Here are the components involved:

1. [Consul](https://www.consul.io/) - for clustering
2. [Nomad](https://www.nomadproject.io/) - for orchestration
3. [Linode](https://cloud.linode.com/) - for hosting
4. [Linode NodeBalancers](https://www.linode.com/nodebalancers/) - for load
   balancing
5. [Let's Encrypt](https://letsencrypt.org/) - for SSL certification
6. [Minio](https://min.io/) - for artifact hosting
6. ...plus a couple small programs to tie it all together

Assuming you've made it this far, you're probably at least a little bit curious
how it works.

## Getting Started

The first thing you'll need to do is provision a couple servers. Serious people
with serious needs will want to consult Hashicorp's [reference
architecture](https://www.nomadproject.io/guides/install/production/reference-architecture.html#one-region),
but for the rest of us, just a few servers will be fine. Here are the ones I
have:

- `server-us-central-1` - for running Consul and Nomad in server mode
- `client-us-central-1` - for running Consul and Nomad in client mode
- `support` - for artifact hosting, cert signing, and other misc. tasks

### Install Consul

...
