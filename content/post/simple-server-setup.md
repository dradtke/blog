+++
date = "2023-09-29"
title = "Simple Server Setup"
draft = true
+++

A few years ago, I decided to take a bit of a deep dive into learning DevOps by building a
HashiStack cluster from scratch (using Consul, Nomad, Vault, Packer, and Terraform), and using it to
run this very blog.

I learned quite a bit along the way, including a number of concepts that I would recommend to anyone
maintaining a medium-to-large system:

- Building with immutable infrastucture, which is the practice of deploying new servers using a
  snapshot created from a fully-configured system, rather than having to run the configuration
  process on new vanilla servers.
- Creating and maintaining an internal certificate authority for intra-cluster communication.
- Deploying applications using an orchestration system (like Nomad or Kubernetes) to enable rapid
  scaling with no downtime.
- Using Terraform and bash scripts to automate the whole thing.

This blog, however, is not a medium-to-large system, and as time goes on, I've found myself less
willing and able to keep up with the type of maintenance that I'd like to, namely keeping the
various systems up-to-date.

In order to simplify maintenance of this site (and as a bonus, to save some money), I'm going to
scrap my HashiStack in favor of a much simpler setup.

The rest of this post will document how I set up the new server for this site, while keeping some
best practices in-mind. It is split broadly into two sections:

1. Server setup (creating and accessing the server)
2. Application setup (running this site on it)

## Server Setup

I'm using Linode as my hosting provider, but other than the user interface, the process will be
largely the same for any provider.

1. Created the server

Using the web UI, I created a new openSUSE Leap 15.5 Nanode. The only paramter needed is the root
password, which for obvious reasons I will not share here.

2. Updated my local SSH config to make access to the server easy

Rather than have to remember the IP address for the new server each time I want to access it, I want
to be able to simply run `ssh damienradtke.com`. To enable that, I added the following section to my
local SSH config file at `~/.ssh/config`:

```
Host damienradtke.com
  HostName 2600:3c06::f03c:93ff:fe96:b5b3
```

The `HostName` value is the IPv6 address for the new Nanode. IPv4 would work just as well, though.

3. Accessed the server

Using the root password I provided while creating the server, I can now access it with:

```sh
$ ssh root@damienradtke.com
```

From here on, the following steps will all be done from the server.

4. Disabled direct SSH access to `root` with password

After getting on to the server, the first step was to update the shared SSH config to disable
logging in with the `root` password again, and then restart the SSH daemon to pick up the changes.
This increases security by ensuring that nobody can access the VM as `root` by somehow guessing the
correct password:

```sh
# sed -i 's/^PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
# service sshd restart
```

4. Created my non-`root` user

Next, I created my user and new home directory, so that I can run operations on the server without
having to be `root` to do them:

```sh
# useradd damien
# mkdir /home/damien
# chown damien:users /home/damien
```

5. Enabled SSH access to `damien`

After logging in as `root`, my computer's SSH public key is stored in `/root/.ssh/authorized_keys`.
In order to enable logging in directly as `damien` in the future, I can simply copy that file to my
new user:

```sh
# mkdir /home/damien/.ssh
# cp /root/.ssh/authorized_keys /home/damien/.ssh/
# chown -R damien:users /home/damien
```

After this step, I can now log in to this server using `ssh damien@damienradtke.com`, rather than as
`root`.

6. Switched to `damien`

At this point I can safely switch to my non-`root` user to perform the remaining operations:

```sh
# su - damien
```

That's it for server setup! Now we can start using it.

## Application Setup

0. Decide What to Run

Before anything can be run, I first have to decide _what_ exactly I want to run.

I want the server to host my website, so I know that I need an HTTP server. There are [quite a
few](https://en.wikipedia.org/wiki/Comparison_of_web_server_software) available, but I decided to
give [Caddy](https://caddyserver.com/) a shot, since I've heard good things about it and I want to
take advantage of its built-in automatic TLS.

1. Installed Necessary Packages

Once I know what I want to run, I can install the packages needed:

```sh
$ sudo zypper refresh
$ sudo zypper install git caddy firewalld
```

2. Started the Firewall

```sh
$ sudo systemctl enable firewalld
$ sudo service firewalld start
```

3. Fetched the source

Now I can fetch the blog's source:

```
$ sudo git clone https://git.sr.ht/~damien/blog /srv/www/damienradtke.com
$ sudo chown -R damien:caddy /srv/www/damienradtke.com
```

### Aside on Filesystem Locations

When running a web server, it's largely a subjective choice of _where_ exactly to place the files,
but there are standards that should generally be followed. Here, I am following the advice given by
openSUSE's documentation on the
[Apache](https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-apache2.html#ex-apache-directives-virtualhost-basic-configuration)
web server, since the `/srv/www/` directory is already present on openSUSE systems.

4. Configured Caddy

The `caddy` package will, by default, make available a configuration file at `/etc/caddy/Caddyfile`
that we can update to provide this site's hostname, and where it should serve its content from:

```
damienradtke.com
root * /srv/www/damienradtke.com/public
file_server
```

5. Started Caddy

Then I just needed to start Caddy running (and ensure that it starts automatically if the server is
ever rebooted):

```sh
$ sudo systemctl enable caddy
$ sudo service caddy start
```

I then confirmed that Caddy was running successfully with

```sh
$ sudo service caddy status
```

6. Updated Firewall

In order to allow external traffic on ports 80 (for HTTP) and 443 (for HTTPS) to reach my web
server, I need to enable those services in the firewall:

```sh
$ sudo firewall-cmd --zone=public --add-service=http
$ sudo firewall-cmd --zone=public --add-service=https
```

5. Updated DNS Records

With Caddy running and serving my site's files, all that's left is to update DNS to point to this
new server! I also manage my DNS records within Linode, so it's easy enough.

<!-- vim: set tw=100: -->
