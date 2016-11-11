+++
date = "2016-11-11T13:15:33-06:00"
title = "Running Fleet Without Docker"
+++

# Introduction

The [CoreOS](https://coreos.com/) project is doing some very interesting work on
how to build, deploy, and scale web applications. Their big focus is to
keep the platform as minimal as possible, which means that everything must be
run as a container. That in turn means that the stock OS doesn't have to worry about
any language runtimes or compilers, since those will be bundled with the app itself.

This all sounds amazing on paper, but Docker isn't without its flaws, and
the kind of orchestration that CoreOS recommends comes with its own
complexities. However, the CoreOS team did develop one project that instantly
caught my eye: [fleet](https://github.com/coreos/fleet). I recently became
interested in the potential of systemd as a web application service manager, and
fleet seemed like a natural extension into the world of clustering.

### Why systemd?

Every web application should be using some kind of process manager. Their most
important function is automatic restart on failure, but depending on which one you
use, they can have other benefits as well. However, every runtime apparently
feels the need to build their own, so you have your choice between
[Supervisor](http://supervisord.org/), [StrongLoop](http://strong-pm.io/),
[God](http://godrb.com/), [Circus](https://circus.readthedocs.io/en/latest/),
[Runit](http://smarden.org/runit/), [Monit](https://mmonit.com/monit/), and
probably a good number more. As a big fan and regular user of openSUSE, my main
reason for picking systemd is that it's already installed and used to manage the
operating system's own services, so why not treat your web application as
just another service? The Ubuntu equivalent is Upstart, but then you have to use
Ubuntu. =)

### Note

The rest of this post assumes that you have some "remote" server to play with,
and that it's running a recent version of openSUSE (though any systemd-based
Linux distribution should work with minor changes). It
could be a container, virtual machine, VPS instance, or even your own colocated
hardware, but you should be able to SSH into it no problem, and have root access for
installing packages and running services.

# A Simple Application

Let's build a very simple web application. The language doesn't really matter,
but Go is nice for Docker-less development because it statically compiles into a
single file, and can even be configured to include all static assets within the
binary. The use-case for Docker becomes quite a bit stronger when using an
interpreted language with a heavy runtime like Ruby or Python.

{{<highlight go>}}
// website.go

package main

import (
    "log"
    "net/http"
)

func index(w http.ResponseWriter, r *http.Request) {
    w.Write([]byte("Hello, World!"))
}

func main() {
    http.HandleFunc("/", index)
    log.Print(" -- server is live --")
    if err := http.ListenAndServe(":8080", nil); err != nil {
        log.Fatal(err)
    }
}
{{</highlight>}}

Deployment will consist of compiling for Linux and `scp`'ing to a predetermined
location. You will need to ensure that your user has write permissions to
`/srv/www` in order for this to work:

{{<highlight sh>}}
$ env GOOS=linux go build -o website website.go
$ scp website <user>@<host>:/srv/www
{{</highlight>}}

# Installing fleet

The `fleet` package isn't in the standard set of openSUSE repositories, so we'll
have to add a new repository to install it (replace `openSUSE_Leap_42.1` with
your version if necessary):

{{<highlight sh>}}
$ sudo zypper ar obs://Virtualization:containers/openSUSE_Leap_42.1 containers
$ sudo zypper ref containers
$ sudo zypper in fleet etcd etcdctl
{{</highlight>}}

That last command actually installs three packages: fleet, etcd, and the
command-line tool for interacting with etcd. etcd is a distributed key-value
store, and it's the mechanism by which fleet communicates across hosts. The
etcdctl package is optional, but nice to have for communicating directly with
etcd if need be.

Once those are installed, start up etcd:

{{<highlight sh>}}
$ su -c 'service etcd start'
{{</highlight>}}

This starts up a single-node etcd cluster listening on `http://localhost:2379`.
The service can be configured by modifying values in `/etc/sysconfig/etcd`, but
the default values will do fine for now.

The next thing to do is start up fleet, but unfortunately, a small config change
needs to be made. Open up `/etc/fleet/fleet.conf` and add the following line:

{{<highlight text>}}
etcd_servers=["http://localhost:2379"]
{{</highlight>}}

Due to what appear to be historical reasons, fleet by default will attempt to
connect to etcd at `http://localhost:4001`, but recent releases of etcd have
begun defaulting to port 2379. Once that's added, start up fleet too:

{{<highlight sh>}}
$ su -c 'service fleet start'
{{</highlight>}}

Verify that they're both running with `su -c 'service <service> status'` before
proceeding.

### Tip: Install fleetctl Locally

Since the whole point of fleet is to act as a single point of entry for an
application cluster, you'll probably want to install the `fleetctl` command line
tool to your local computer. Fleet itself only supports Linux, but you can
install fleetctl anywhere (albeit with some issues on
[Windows](https://github.com/coreos/fleet/issues/1043)).

Managing a fleet locally with fleetctl requires it to be able to access machines
via SSH publickey (password-based authentication won't work), so you'll need to
add your local user's public SSH key to your remote user's `~/.ssh/authorized_keys`
file.

Once it's installed and your public key is configured, test your connection like
so:

{{<highlight sh>}}
$ fleetctl --tunnel=<remote-ip> --ssh-username=<remote-username> \
    --endpoint=http://localhost:2379 list-machines
MACHINE		IP		METADATA
17d98101...	74.122.197.234	-
{{</highlight>}}

The `--tunnel` option lets you run commands locally as if you were running them
from `<remote-ip>`, `--ssh-username` specifies which user to SSH in as, and
`--endpoint` specifies which etcd endpoint to connect to. Note that the
endpoint is resolved relative to the remote host, not locally, and that it
uses the exact same value we added to `fleet.conf` earlier.

If all went well, your terminal should print out some information about your
remote host, including a truncated machine id and IP address.

### Tip: Alias fleetctl

Once you've confirmed that `fleetctl` works with the options above, it's a good
idea to create an alias so that you don't have to manually type the options
every time. With this, writing `fleetctl list-machines` does the exact same
thing as above:

{{<highlight sh>}}
$ alias fleetctl='fleetctl --tunnel=<remote-ip> --ssh-username=<remote-username> --endpoint=http://localhost:2379'
{{</highlight>}}

# Create a Unit File

Getting fleet and etcd up and running, and being able to communicate with it,
are the hard parts. Now all that's left is defining your application as a
unit file and loading it up!

CoreOS has a good
[introduction](https://coreos.com/docs/launching-containers/launching/getting-started-with-systemd/)
to systemd and unit files, but for now we'll start with something very simple.
Note that this file should be created locally; `fleetctl` will take care of
uploading it to the server and making use of it.

{{<highlight text>}}
# website.service

[Unit]
Description=My Awesome Website!

[Service]
ExecStart=/srv/www/website
{{</highlight>}}

At its absolute simplest, this just sets a description and tells systemd how to
start the service. There are a whole host of other options and configurations
you can do, some of them fleet-specific, but this is enough to be able to get
something running.

# Start the Application

First, we need to tell fleet about our application:

{{<highlight sh>}}
$ fleetctl submit website.service
Unit website.service inactive
{{</highlight>}}

You can then verify that it was accepted:

{{<highlight sh>}}
$ fleetctl list-unit-files
UNIT			HASH	DSTATE		STATE		TARGET
website.service		6f60fd0	inactive	inactive	-
{{</highlight>}}

If your output looks like this, then you're good to start it up.

{{<highlight sh>}}
$ fleetctl start website.service
Unit website.service launched on 17d98101.../74.122.197.234
{{</highlight>}}

And then verify that it's up and running...

{{<highlight sh>}}
$ fleetctl list-units
UNIT			MACHINE				ACTIVE	SUB
website.service		17d98101.../74.122.197.234	active	running

$ fleetctl status website.service
website.service - My Awesome Website!
   Loaded: loaded (/run/fleet/units/website.service; linked-runtime)
   Active: active (running) since Fri 2016-11-11 16:26:54 CST; 1min 13s ago
 Main PID: 2260 (website)
   CGroup: /system.slice/website.service
           └─2260 /srv/www/website
{{</highlight>}}

And that's it!

# Taking it Further

Naturally, the next step would be to begin scaling the application out to
multiple hosts and to begin introducing additional services, like a database.
Scaling to multiple hosts is a discussion for another day, and mostly revolves
around setting each one up with an etcd/fleet installation, and then configuring
etcd correctly.

Using fleet without containers means that additional services will need to
be installed normally, but configured with fleet. One easy way to do this is to
cheat a little bit by copying the installation's service file to your local
project, which also lets you add some fleet-specific settings if necessary. As
an example, here's how you would start Postgres running as part of your fleet
cluster:

{{<highlight sh>}}
$ scp <user>@<host>:/usr/lib/systemd/system/postgresql.service .
$ fleetctl start postgresql.service # will submit the file on first run
{{</highlight>}}

# Conclusion

Most use-cases for fleet will still involve Docker and CoreOS, but as you can
see, it is entirely possible to install and use it independent of those tools,
and doing so can provide you with a flexible scaling solution for those of you
who don't want to commit to a kitchen-sink solution.
