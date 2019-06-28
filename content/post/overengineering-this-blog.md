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
- `support` - for [artifact hosting](https://min.io/) and [certificate signing](https://github.com/cloudflare/cfssl)

For information on the differences between server and client mode, check out the
associated docs for [Consul](https://www.consul.io/docs/agent/basics.html) and
[Nomad](https://www.nomadproject.io/intro/getting-started/running.html). I also
won't go into much detail on the setup of `support`, since all we need from it
for this post is the artifact hosting; setting up your own S3 bucket or Minio
server is left as an exercise for the reader.

The rest of this post assumes that you've chosen a distribution with systemd for
the client and server nodes, since that will be used to run Consul and Nomad as
services. I personally am running openSUSE, which incidentally is one of the
reasons that I chose Linode, since unfortunately not many other VPS providers
make it an option.

### Installing Hashicorp Tools

Once these servers are provisioned, the next few steps will involve getting
Consul and Nomad installed on them. We have a couple different options here:

1. Compile from source
2. Download from your distribution's package manager
3. Download from Hashicorp's release page

The first option is the most complex, and I only recommend it if you want a
challenge or are already familiar with building these projects yourself.

Between the two simpler options, I chose to go with installing directly from
Hashicorp, because there's no lag when a new version is released, and each one
comes built with the web UI, which is pretty handy to have once things are up
and running.

The downside to installing directly from Hashicorp is that it takes a little
work to follow their [security best
practices](https://www.hashicorp.com/security), which involves verifying the
download using a checksum and ensuring that the checksum was signed by
Hashicorp. Fortunately, I've already written a Bash script that handles this for
you:

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
since this is how the client knows how to connect to the cluster. Note that we
are not using the public IP; in fact, the only IP address we truly care about
for this post is the private IP of each node. The only public IP we want to use
is the NodeBalancer's.

Once that's in place, start the service here as well, and hopefully you will now
see something like this:

{{< highlight bash >}}
$ consul members
Node                 Address               Status  Type    Build  Protocol  DC          Segment
server-us-central-1  192.168.174.116:8301  alive   server  1.5.1  2         us-central  <all>
client-us-central-1  192.168.167.74:8301   alive   client  1.5.1  2         us-central  <default>
{{< /highlight >}}

If you'd like to see the web UI, SSH back onto `server-us-central-1` with port
forwarding (`ssh -L 8500:localhost:8500 ...`), and then you should be able to
see it at http://localhost:8500/ui/

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

{{< gist dradtke 7a3d6477666c05e4558b990630c5a5ca >}}

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
simplicity, I decided to go with Linode's offering. Creating one is fairly
straightforward through their web interface:

![Creating a NodeBalancer](/images/overengineering-this-blog/create-nodebalancer.png)

The important parts to note are:

1. The configuration listens to HTTP on port 80, so that we can visit the
   website without having to specify a port. 
2. The backend node's IP address is the private IP of `client-server-us-central-1`.
3. The backend node's port is the one that we know Hugo is listening on.

If you create this and wait a little bit, you should now be able to see the
website by visiting the IP address of the NodeBalancer.

Alright, we now have a working load-balanced blog, but there's a problem: since
we're using dynamic port allocation, any time we restart the server task, the
site will break because it will get assigned a new port that the NodeBalancer
doesn't know about. To fix this, we need to alert Linode whenever our task's
port changes.

## Listening for Changes

Besides clustering, the other big benefit we get from Consul is the ability to
set up a [watch](https://www.consul.io/docs/agent/watches.html#service) that
will let us react to changes in a running service. When a change in the running
service is detected, the watch will execute a script of our choosing, passing it
a JSON payload describing the service in its current state. An example of the
payload can be seen on the documentation page.

Because we want to update the NodeBalancer on each service change, we will need
to write a script that uses Linode's API to make those changes. I chose to write
my script in Ruby, but any scripting language with reasonable JSON and HTTP
support would work.

In order to interact with Linode's API, you will need an [Access
Token](https://www.linode.com/docs/platform/api/getting-started-with-the-linode-api/#get-an-access-token),
and specifically one with Read/Write access to NodeBalancers. Once you
have one, save this script as `/usr/local/bin/balance.rb`, replacing the value
of `API_KEY` with your newly-created Access Token:

{{< gist dradtke 5562e1cab015c9dc3aff7ab4f9fba8c9 >}}

Note also that this script uses the `httparty` gem, so you may need to run `gem
install httparty` before executing this script in order for it to work.
This script would be better if it used a proper Linode API gem, but none of the
ones I found were well-documented or seemed to work with the new v4 API.

The script takes two arguments: the name of the balancer, and the port
specifying which config to update. It works by locating the NodeBalancer config
to be updated, querying its configured backend nodes, and then making the
necessary deletions + additions so that it matches the watch payload, which is
provided through standard input.

(Note that we need to provide a label for new backend nodes, but we don't really
care what it is, so we just shell out to `uuidgen` and strip its dashes in order
to fit within the character limit.)

With this in place, we just need to add a new Consul configuration file
`/etc/consul.d/watches.hcl` with the following contents:

{{< highlight hcl >}}
watches {
    type = "service"
    service = "damienradtkecom-server"
    handler_type = "script"
    args = ["/usr/local/bin/balance.rb", "damienradtkecom", "80"]
    passingonly = true
}
{{< /highlight >}}

This tells Consul to set up a `service` watch that will invoke our `balance.rb`
script with the specified arguments whenever a change to the
`damienradtkecom-server` task is detected. Make sure to restart Consul so that
it picks up the change!

To test it, run `nomad job stop damienradtke`, and after a few moments ensure
that there are no backend nodes configured on the NodeBalancer. Re-start the job
with `nomad job run damienradtkecom.nomad`, and after a few moments it should
once again have a backend node whose IP address matches the client's private IP,
and whose port you can verify in the allocation's log output.

At this point, we have completed the bare minimum to successfully scale this
blog out to an arbitrary number of nodes, but there's a big piece missing still:
SSL.

#### An Aside on IP Addresses

Note that we define `want` in the script by grabbing the IP address from the
node, rather than the value advertised by the service. Why? Well, in theory,
you can tell Nomad which IP address services should advertise by setting the
[network_interface](https://www.nomadproject.io/docs/configuration/client.html#network_interface)
value. If you run `ip addr`, you will see the available interfaces:

{{< highlight text >}}
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether f2:3c:91:ad:be:1d brd ff:ff:ff:ff:ff:ff
    inet 66.228.52.180/24 brd 66.228.52.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet 192.168.174.116/17 brd 192.168.255.255 scope global eth0:1
       valid_lft forever preferred_lft forever
[...]
{{< /highlight >}}

The first interface, `lo`, is the loopback interface, which is used for
connections to `localhost` and only works from the node to itself. Linodes are
configured with only one other interface, `eth0`, which defines both the public
(`66.228.52.180`) and private (`192.168.174.116`) IP addresses. Most of
Nomad's networking settings will default to the first private IP address, but
services will advertise themselves using the first _public_ IP address. Since we
only want to access these services via the NodeBalancer, we actually want them
to advertise themselves using the private IP as well; however, this is currently
impossible with Nomad because the private IP shares `eth0`, and it's [currently
impossible](https://github.com/hashicorp/nomad/issues/3675) to use the more
specific `eth0:1` alias. Once that issue is fixed, the script can be updated to
grab both the IP and port from the service definition itself, but until then we
can use the node's IP, since that one is properly configured as the private IP.

## Setting up SSL

At this point, we have a website successfully being served by a load balancer
over HTTP. However, we want our website to be secure, so we want to set up SSL
and naturally that means using [Let's Encrypt](https://letsencrypt.org/). One
cool feature of Linode's NodeBalancers is that you can [configure
them](https://www.linode.com/docs/platform/nodebalancer/nodebalancer-ssl-configuration/)
to terminate SSL, which means we only need to install the certificate in one
location no matter how many instances of the site we're running.

There are several different ways to go about integrating Let's Encrypt based on
the different [challenges](https://letsencrypt.org/docs/challenge-types/)
available. For this post, we'll stick with the standard HTTP-01 challenge, though
it's certainly possible to use DNS-01 if your domain is managed through Linode
or some other domain manager with an API.

The HTTP-01 challenge works by creating a special file that Let's Encrypt will
then query for over HTTP. This means that a certificate renewal process will
need to include a webserver, which we will configure to be the new listener for
port 80, as well as a process for initiating the renewal periodically.

With these in mind, I decided to write it as a Go program using `acme/autocert`,
which makes it super simple to both listen for challenges, and to initiate the
renewal:

{{< gist dradtke 35f115f88ba25db697ca9dea858f1504 >}}

Note that here you also need to update it to include your own Access Token, one
with Read/Write access to NodeBalancers.

Now we will need to take advantage of `support`, or an S3 bucket if you don't
want to set up Minio. The above program should be compiled into a 64-bit Linux
binary and hosted, and then we can add a task for it to `damienradtkecom.nomad`:

{{< gist dradtke f44ef9f49eede472c463b50bbbb7aae7 >}}

We create a separate task group here because we will only ever want 1 of these
running, even if we scale up the number of servers. The definition of the task
itself is super straightforward, since all it does is configure a port for HTTP,
download the binary, and execute it.

TODO: talk about needing to use raw_exec, or add SSL certs to the chroot.
