+++
date = "2019-06-24"
title = "Overengineering This Blog"
enableInlineShortcodes = true
draft = true
+++

Lately, I've taken quite an interest in a couple things: the Hashicorp stack,
and building distributed systems on top of VPS providers rather than a cloud
like AWS. As a result, this very blog, a Hugo-powered static site which used to
run on a single node via nginx, is now running on a Nomad cluster deployed with
Linode, so while it is still technically running on just a single node as of
this writing, I can now needlessly scale this site to my heart's content should
I ever feel the urge to do so. To prove it, here is the Nomad allocation ID
assigned to this process: <strong>{{< alloc_id >}}</strong>

Here are the components involved:

1. [Consul](https://www.consul.io/) - for clustering
2. [Nomad](https://www.nomadproject.io/) - for orchestration
3. [Linode](https://cloud.linode.com/) - for hosting
4. [Linode NodeBalancers](https://www.linode.com/nodebalancers/) - for load
   balancing
5. [Let's Encrypt](https://letsencrypt.org/) - for SSL certification
6. ...plus a couple small programs to tie it all together

Assuming you've made it this far, you're probably at least a little bit curious
how it works.

## Getting Started

The first thing you'll need to do is provision a couple servers. Serious people
with serious needs will want to consult Hashicorp's [reference
architecture](https://www.nomadproject.io/guides/install/production/reference-architecture.html#one-region),
but for the rest of us, just a couple servers will be fine. Here are the ones I
have:

- `server-us-central-1` - for running Consul and Nomad in server mode
- `client-us-central-1` - for running Consul and Nomad in client mode

For information on the differences between server and client mode, check out the
associated docs for [Consul](https://www.consul.io/docs/agent/basics.html) and
[Nomad](https://www.nomadproject.io/intro/getting-started/running.html).

(I also have an additional `support` node for [artifact hosting](https://min.io/)
and [certificate signing](https://github.com/cloudflare/cfssl), but we won't
need those for the scope of this post.)

The rest of this post assumes that you've chosen a distribution with systemd,
since that will be used to run Consul and Nomad as services. I personally am
running openSUSE, which incidentally is one of the reasons that I chose Linode,
since unfortunately not many other VPS providers make it an option.

### Installing Hashicorp Tools

Once these servers are provisioned, the next few steps will involve getting
Consul and Nomad installed on them. We have a couple different options here:

1. Compile from source
2. Download from your distribution's package manager
3. Download from Hashicorp's release page

The first option is the most complex, and I only recommend it if you want a
challenge or are already familiar with building these projects yourself.

Between the two saner options, I chose to go with installing directly from
Hashicorp, because there's no lag when a new version is released, and each one
comes built with the web UI, which is pretty handy to have once things are up
and running.

The downside to installing directly from Hashicorp is that you have to make sure
you follow their [security best practices](https://www.hashicorp.com/security),
which involves verifying the download using a checksum and ensuring that the
checksum was signed by Hashicorp. Fortunately, I've already written a Bash
script that handles this for you:

{{< gist dradtke e5da8eb5295519abe712b4ee8d1f6d9a >}}

Download this script to each server, and then run the following to install
Consul 1.5.1 and Nomad 0.9.3, the latest releases as of this writing:

{{< highlight bash >}}
$ install-hashicorp.sh consul 1.5.1
$ install-hashicorp.sh nomad 0.9.3
{{< /highlight >}}

This installs them as `/usr/local/bin/consul-1.5.1` and
`/usr/local/bin/nomad-0.9.3`. To make them available as the usual `consul` and
`nomad` commands, you can symlink them. This makes it really easy to update the
version you're running on each host:

{{< highlight bash >}}
$ ln -s /usr/local/bin/consul-1.5.1 /usr/local/bin/consul
$ ln -s /usr/local/bin/nomad-0.9.3 /usr/local/bin/nomad
{{< /highlight >}}

## Creating systemd Services

The next step is to create `consul` and `nomad` services so you can run them in
the background. Hashicorp actually provides service files for both
[Consul](https://learn.hashicorp.com/consul/datacenter-deploy/deployment-guide#configure-systemd)
and
[Nomad](https://github.com/hashicorp/nomad/blob/master/dist/systemd/nomad.service),
all you have to do is save those as `consul.service` and `nomad.service` in
`/etc/systemd/system`.

The next step is to set up users and home directories for these services. Here's
how you would create a new dedicated user and home directory for Consul:

{{< highlight bash >}}
$ mkdir /var/lib/consul
$ groupadd consul
$ useradd --gid consul --home-dir /var/lib/consul consul
$ chown consul:consul /var/lib/consul
{{< /highlight >}}

Now do the same for Nomad, but the final three commands should be run _only_ on
`server-us-central-1`. The client agent must be run as root in order to provide
resource isolation. Along with this, you will want to edit `nomad.service` on
`server-us-central-1` to add `User=nomad` and `Group=nomad` directives.

{{< highlight bash >}}
$ mkdir /var/lib/nomad  # needed on both server and client
$ groupadd nomad
$ useradd --gid nomad --home-dir /var/lib/nomad nomad
$ chown nomad:nomad /var/lib/nomad
{{< /highlight >}}

Before these services will be able to run, though, we'll need to add some
configuration.

To ensure that the service files have been installed correctly, you can run
`systemctl list-unit-files` and ensure that both `consul.service` and
`nomad.service` appear in the output.

## Configuring Consul

Now that our services are installed, the next step is to get the Consul cluster
up and running, because that is what Nomad will use for inter-cluster
communication. Applications running in client and server mode will need to be
configured differently, though overall they're pretty similar.

Here's a basic configuration file for Consul, which you should save as
`/etc/consul.d/consul.hcl` on `server-us-central-1`:

{{< highlight hcl >}}
bind_addr = "{{ GetInterfaceIP `eth0` }}"
datacenter = "us-central"
node_name = "server-us-central-1"
data_dir = "/var/lib/consul"

server = true
bootstrap_expect = 1
ui = true
{{< /highlight >}}

This configuration provides some basic node information, and tells Consul to run
in server mode. The `bootstrap_expect` value should be set to the number of
server nodes you are running; since this is our only one, we set it to `1`.

You should now be able to start Consul:

{{< highlight bash >}}
$ service consul start
{{< /highlight >}}

If you're relatively new to managing services with systemd, the following
commands are your friends when figuring out if things are working:

{{< highlight bash >}}
$ service consul status
$ journalctl -u consul
$ journalctl -fu consul  # follow mode
{{< /highlight >}}

Assuming all went well, you should now be able to query the cluster for member
information:

// TODO: figure out how to get this to display better

{{< highlight bash >}}
$ consul members
Node                 Address               Status  Type    Build  Protocol  DC          Segment
server-us-central-1  192.168.174.116:8301  alive   server  1.5.1  2         us-central  <all>
{{< /highlight >}}

Success! Your cluster is now running! The next step is to configure the client,
using this config file that should be saved in the same place on
`client-us-central-1`:

{{< highlight hcl >}}
bind_addr = "{{ GetInterfaceIP `eth0` }}"
datacenter = "us-central"
node_name = "client-us-central-1"
data_dir = "/var/lib/consul"

server = false
retry_join = ["..."]
{{< /highlight >}}

For `retry_join`, put the private IP address belonging to `server-us-central-1`,
since this is how the client knows how to connect to the cluster.

Once that's in place, start the service here as well, and hopefully you will now
see something like this:

{{< highlight bash >}}
$ consul members
Node                 Address               Status  Type    Build  Protocol  DC          Segment
server-us-central-1  192.168.174.116:8301  alive   server  1.5.1  2         us-central  <all>
client-us-central-1  192.168.167.74:8301   alive   client  1.5.1  2         us-central  <default>
{{< /highlight >}}

To see the web UI, SSH back onto `server-us-central-1` with port forwarding
(`ssh -L 8500:localhost:8500 ...`), and then you should be able to see it at
http://localhost:8500/ui/

![Consul UI](/images/overengineering-this-blog/consul-ui.png)

Check out [Consul's documentation](https://www.consul.io/docs/agent/options.html)
For more information or additional configuration options.

## Configuring Nomad

This section may bear some eerie resemblance to the previous one. To start, place
this in `/etc/nomad.d/nomad.hcl` on `server-us-central-1`:

{{< highlight hcl >}}
region = "us"
datacenter = "us-central"
data_dir = "/var/lib/nomad"

server {
    enabled = true
    bootstrap_expect = 1
}

consul {
    address = "localhost:8500"
}
{{< /highlight >}}

Note that Nomad adds an additional location concept called `region`, which is
separate from `datacenter`. The exact values are up to you, but the idea is that
one region contains multiple datacenters, and Nomad servers operate in groups by
region.

Go ahead and start Nomad:

{{< highlight bash >}}
$ service nomad start
{{< /highlight >}}

Assuming Nomad is now running, you should be able to query the servers in the
Nomad cluster with `nomad server members`:

{{< highlight text >}}
Name                    Address          Port  Status  Leader  Protocol  Build Datacenter  Region
server-us-central-1.us  192.168.174.116  4648  alive   true    2         0.9.3 us-central  us
{{< /highlight >}}

Now here comes the real magic, which is configuring the Nomad client. To do
that, put the following in `/etc/nomad.d/nomad.hcl` on `client-us-central-1`:

{{< highlight hcl >}}
region = "us"
datacenter = "us-central"
data_dir = "/var/lib/nomad"

client {
    enabled = true
}

consul {
    address = "localhost:8500"
}
{{< /highlight >}}

Notice that there is no mention of the Nomad server in here at all! That's
because Nomad uses its connection with Consul to locate the server, meaning that
you only have to configure the cluster once with Consul, and then piggyback on
that work with Nomad.

Once Nomad is up and running here too, you should be able to check on its status
(from either the client or server node) with `nomad node status`:

{{< highlight text >}}
ID        DC          Name                 Class   Drain  Eligibility  Status
6f6d04b5  us-central  client-us-central-1  <none>  false  eligible     ready
{{< /highlight >}}

To see the web UI, SSH back onto `server-us-central-1` with port forwarding
(`ssh -L 4646:localhost:4646 ...`), and then you should be able to see it at
http://localhost:4646/ui/

![Nomad UI](/images/overengineering-this-blog/nomad-ui.png)

## Creating the Job

Now that we have a Nomad cluster running, we can define our job and submit it.
This website is built with [Hugo](https://gohugo.io/) and the source code is
stored at https://github.com/dradtke/blog, so I decided to create a job that
takes advantage of Hugo's built-in web server and pulls blog content directly
from Github:

{{< highlight hcl >}}
job "damienradtkecom" {
    region = "us"

    datacenters = ["us-central"]
    type = "service"

    group "server" {
        count = 1

        task "server" {
            driver = "exec"
            config {
                command = "hugo"
                args = [
                    "server",
                    "--config=local/blog/config.toml",
                    "--watch=false",
                    "--bind=0.0.0.0",
                    "--port=${NOMAD_PORT_http}",
                    "--contentDir=local/blog/content",
                    "--layoutDir=local/blog/layouts",
                    "--themesDir=local/blog/themes",
                ]
            }

            service {
                name = "${JOB}-${TASK}"
                port = "http"
            }


            resources {
                network {
                    port "http" {}
                }
            }

            artifact {
                source = "github.com/dradtke/blog"
                destination = "local/blog/"
                options {
                    ref = "d60dd4a75d7d4015e6d0109e15e3fb46d31cd6bc"
                }
            }

            artifact {
                source = "https://github.com/gohugoio/hugo/releases/download/v0.55.6/hugo_0.55.6_Linux-64bit.tar.gz"
                options {
                    checksum = "sha256:39d3119cdb9ba5d6f1f1b43693e707937ce851791a2ea8d28003f49927c428f4"
                }
            }
        }
    }
}
{{< /highlight >}}

This job makes heavy use of [Nomad
artifacts](https://www.nomadproject.io/docs/job-specification/artifact.html),
downloading the specified version of Hugo and cloning the blog's code at the
specified `ref` at startup time.

There are a couple things to note about how this is implemented. First, you may
notice the long list of arguments to `hugo`. That is because the repo cannot be
cloned directly into the working directory, which is where Hugo expects to find
the config file and content, layout, and theme directories by default. Rather,
the source gets cloned to `local/blog/`, and then the arguments to Hugo let us
tell the server where that data can be found. An alternative approach would be
to use bash as your executable and then pass it an inline script, but it doesn't
end up being less verbose and forces you to place all options on one line.
However, this may be a good option for programs that require a specific working
directory:

{{< highlight hcl >}}
command = "bash"
args = ["-c", "cd local/blog && exec hugo ..."]
{{< /highlight >}}

Second, the port declaration instructs Nomad to allocate a [dynamic
port](https://www.nomadproject.io/docs/job-specification/network.html#port-parameters)
for this task named `http`. We can then reference the value chosen by Nomad in
the [environment variable](https://www.nomadproject.io/docs/runtime/environment.html)
`NOMAD_PORT_http`, which we pass on to Hugo.

This job file can be submitted from anywhere that can connect to the Nomad
cluster, but for simplicity, let's save it as `damienradtkecom.nomad` on
`server-us-central-1` and run it from there:

{{< highlight bash >}}
$ nomad job run damienradtkecom.nomad
==> Monitoring evaluation "209146c3"
    Evaluation triggered by job "damienradtkecom"
    Allocation "5a563989" created: node "6f6d04b5", group "server"
    Evaluation status changed: "pending" -> "complete"
==> Evaluation "209146c3" finished with status "complete"
{{< /highlight >}}

You can then check on the result and get the output of the running task:

{{< highlight bash >}}
$ nomad job status damienradtkecom
ID            = damienradtkecom
Name          = damienradtkecom
Submit Date   = 2019-06-25T21:16:54Z
Type          = service
Priority      = 50
Datacenters   = us-central
Status        = running
Periodic      = false
Parameterized = false

Summary
Task Group   Queued  Starting  Running  Failed  Complete  Lost
server       0       0         1        0       1         0

Allocations
ID        Node ID   Task Group   Version  Desired  Status    Created    Modified
5a563989  6f6d04b5  server       2        run      running   2m19s ago  2m ago
{{< /highlight >}}

{{< highlight bash >}}
$ nomad alloc logs 5a563989
Building sites …
                   | EN
+------------------+----+
  Pages            | 22
  Paginator pages  |  0
  Non-page files   |  0
  Static files     |  6
  Processed images |  0
  Aliases          |  0
  Sitemaps         |  1
  Cleaned          |  0

Total in 502 ms
Environment: "development"
Serving pages from memory
Running in Fast Render Mode. For full rebuilds on change: hugo server --disableFastRender
Web Server is available at http://localhost:24868/ (bind address 0.0.0.0)
Press Ctrl+C to stop
{{< /highlight >}}

Success! We can see from the output that Hugo is running on port `24868`. To see
that it's up and running, curl `http://<client-ip>:24868/`, where `<client-ip>`
is the public IP address of `client-us-central-1`.

That's all well and good, but who wants to visit a website hosted publicly on
port 24868?

## Enter the NodeBalancer

There are many solutions out there for load balancing, but for the sake of
simplicity, I decided to go with Linode's offering. It has some downsides,
notably that all balanced servers have to be in the same datacenter, but it's
still a good option, especially if you're already running on Linode.
