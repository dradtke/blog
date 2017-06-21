+++
date = "2017-06-16T16:25:58-07:00"
title = "Deploying openSUSE on Vultr"
+++

As an avid openSUSE user and fan, I wish more VPS providers supported openSUSE
images. Linode and Amazon both do, and there's nothing wrong with them, but I
recently learned about Vultr's [custom
ISO](https://www.vultr.com/features/uploadiso/) feature and decided to try to
bring openSUSE to Vultr! Vultr provides guides for installing CoreOS and
Gentoo, after all, so why not openSUSE?

<!--more-->

# Step One: Create a Vultr Account

This is pretty easy and self-explanatory, but in order to try this out, you'll
need a [Vultr](https://www.vultr.com/) account, and a payment method hooked up
to the account for billing.  Once you've completed that, move on to step two.

# Step Two: Upload desired ISO

The first thing you'll need to do with your account is to upload the openSUSE
ISO to it. Go to `Servers -> ISO` and click the "Add ISO" button. On the next
page you'll need to provide a URL from where the file can be downloaded. For
installing 64-bit openSUSE Leap 42.2, you can use this one, but any valid
openSUSE ISO link will do:

```
http://download.opensuse.org/distribution/leap/42.2/iso/openSUSE-Leap-42.2-NET-x86_64.iso
```

Then click Upload and wait a little bit for it to land in your account.

# Step Three: Prepare AutoYaST

openSUSE's solution to automated installations is
[AutoYaST](https://doc.opensuse.org/projects/autoyast/), which allows you to
kick off the installation with a predefined set of instructions describing what
you want. These instructions are contained within a "control file."

## Create an AutoYaST Control File

The [control file](https://doc.opensuse.org/projects/autoyast/#Profile) is an
XML file describing the desired installation. There are a _lot_ of details that
can go into a control file, but here's a simple one to get you started (based
off of [this
one](https://github.com/openSUSE/vagrant/blob/master/http/42.2-general.xml)
designed for use with Vagrant):
[autoinst.xml](/extras/opensuse-vultr/autoinst.xml)

Important note: Vultr mounts the instance's hard disk at `/dev/vda`, _not_
`/dev/sda` like you would normally see. Make sure that the installation target
is set correctly or the installation will fail.

If you don't want to make any customizations to the control file, feel free to
grab the link for the example and use that as the `autoyast` value in step four.
If you do want to make any changes, though, read on.

## Make the Control File Available

Once you have a control file, you'll have to make it available to the
installation process. There are two ways to do this:

1. Use the same server and load the control file locally
2. Use a different server and load the control file over HTTP

The first option only works if you're installing from a Live CD (full
disclosure: I have not actually tried that approach, so it may not work at all,
but it seems like something that would).  If you're using an ISO from the front
page of https://software.opensuse.org, however, there is no live session to boot
into, so we'll go with the second option.

UPDATE: Since writing this post, a commenter on Reddit pointed out that you can
use a public pasting service such as Pastebin to host the control file, which is
quite a bit easier than the following advice that I originally recommended. If
you follow that approach, make sure you use the _raw_ URL, and feel free to skip
the next section and go straight to step four!

### Create an Intermediate Server

In order to serve the control file from another location, we'll first have to
create the other location. This server will be short-lived and can be destroyed
after the openSUSE installation has kicked off. For the rest of this post, I'm
going to assume a control file name of `autoinst.xml`.

Once you've created it, upload it to the server:

```sh
$ scp autoinst.xml root@<ip address>:~
```

The last step is to begin serving it over HTTP. The simplest way is to use
something like [devd](https://github.com/cortesi/devd), which can be installed
easily:

```sh
# Run from the server as root
$ curl -L https://github.com/cortesi/devd/releases/download/v0.7/devd-0.7-linux64.tgz \
  | tar xz --directory=/usr/local/bin --strip-components=1 devd-0.7-linux64/devd
```

Now make sure that any firewall is disabled (`systemctl stop firewalld` on
CentOS 7) and begin serving requests in the local directory:

```sh
# Run from the server as root, in the same folder as autoinst.xml
$ devd --address=0.0.0.0 .
```

# Step Four: Install!

Now comes the magic. Boot up a new server using the openSUSE ISO, and use
Vultr's "View Console" feature to see the server's output over VNC. Once you see
the Grub screen with "Installation", etc., press Escape, then Enter, then enter
the following boot command:

```
linux nomodeset autoyast=http://<ip address>/autoinst.xml
```

Note that the IP address in the `autoyast` parameter should be the IP of the
server hosting `autoinst.xml`.

Now go make yourself a cup of coffee or something while the installation runs;
it will take a little while.

As soon as the installation is complete, you should be able to access the server
via SSH with username `root` and password `password` (more secure options can,
and should, be set by modifying the AutoYaST control file).

And that's it! Enjoy your new Vultr openSUSE instance.
