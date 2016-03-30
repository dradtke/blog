+++
date = "2016-03-29T22:03:32-05:00"
title = "Building a Giphy viewer in GTK+"
draft = true
+++

Web applications get all the hype these days, so why not buck the trend
and build a desktop application instead? In this post I'm going to use GTK+
to build a simple desktop program for integrating with Giphy's API.

<!--more-->

**NOTE**: Windows and Mac users will unfortunately not be able to run
the example code, but stick around for a little bit anyway and you may
still learn something neat.

To whet your appetite, here's a preview of what it is that we're actually
trying to build:

{{< figure src="/images/gtk-giphy/giphy-homer.gif" class="regular" >}}

<div style="text-align: center;">
  64-bit Linux download:
  <a href="/extras/gtk-giphy/giphy-viewer" download>executable</a>
  /
  <a href="/extras/gtk-giphy/giphy-viewer.sha1" download>checksum</a>
</div>
<br>

Functionally, this app isn't too complicated. You type in a search term,
hit Enter, and it will look up and display a random GIF matching your query.
Giphy provides an endpoint for this, so all we have to do is build the UI
around it.

## Setting Up

This post is going to be focused on GNOME technologies, so you need to be
running Linux (GTK+ is fully cross-platform, but the other modules used
here aren't to my knowledge), know the basics of using a command line,
and how to use your package manager to install runtime libraries and development
tools.

To begin, you will need to install the Vala compiler (I'm using 0.28.1), and
development libraries for the following packages (my version listed as well,
but other versions may work too):

1. `gtk+-3.0` (3.16.7)
2. `libsoup-2.4` (2.50.0)
3. `json-glib-1.0` (1.0.4)

You can make sure they're installed properly by running `pkg-config --modversion
<package>`, and if you get a message telling you that the package wasn't found,
then you are missing the development tools.

## About Vala and GNOME Development

Why am I targeting GNOME? Frankly, because it's what I use (currently running
GNOME 3 via openSUSE Leap; go check it out if you haven't heard of it!), and the
GNOME API's are actually fairly pleasant to work with.

If you'd like, this entire application can be written in pure C (as opposed to
the Qt framework which requires C++), but another benefit of targeting GNOME
technologies is that it has its own C#-inspired language that compiles to C: Vala.
As a result, applications written in Vala are just as fast as ones written in C,
but you get a language whose usability is on par with Python.

## Running the Examples

Each part comes with a tar archive containing the source code that summarizes
what was covered. Each example archive contains two files: the Vala source code,
and a Makefile. To run each one, extract the contents, `cd` into the folder,
and execute `make run`. Assuming your development environment is set up correctly,
then the application will run.

# Part I: Hello World

(the source for this section can be found [here][1])

For the first part of this post, we're just going to set up a Hello World application
that we can further extend. Unlike most GTK+ Hello World applications, though,
we're going to use some of GNOME's tools for building an actual application, and
not just a window full of widgets.

GNOME applications are beginning to make a distinction between two main scopes:
application-level and window-level. It's no big surprise that you can have multiple
windows of an application open at a time, and GNOME is embracing that usage pattern by
allowing you to separate the concerns of the application on a global level with those
that are only concerned with one window at a time.

For example, imagine that our Giphy Viewer is already built. If you'd like to do
two searches at the same time, say to compare results, you'd open up two Giphy Viewer
windows. Each window would contain the search field, and the image result. However,
application settings should always be the same between the two. If the application
is made to be more configurable, and the user wants to provide his or her own API key,
that key should be available to any and all open windows.

As a result, the Hello World is broken down roughly into three sections:

{{<highlight vala>}}
public class Window : Gtk.ApplicationWindow {
    ...
}

public class Application : Gtk.Application {
    ...
}

int main(string[] args) {
    return new Application().run(args);
}
{{</highlight>}}

From top-to-bottom, these sections are:

1. The application's `Window` class. This represents a single open instance of your
   application.
2. The application's `Application` class. This represents the global, application-wide
   state of your application.
3. The `main` method, which is the entrypoint for Vala programs. This part is already
   basically complete, as all it does is instantiate the `Application` class and start
   it running.

Note that Vala's syntax means that `Window` extends the `ApplicationWindow` class defined
in the `Gtk` namespace, and `Application` extends the `Application` class defined in the
`Gtk` namespace.

The `Window` class' Hello World implementation is the simpler of the two, so let's
cover that one first:


{{<highlight vala>}}
public class Window : Gtk.ApplicationWindow {
    public Window(Application app) {
        Object(application: app, title: "Search Giphy");
        this.show();
    }
}
{{</highlight>}}

The `Gtk.ApplicationWindow` class requires a constructor that takes an instance of a
`Gtk.Application`, so the constructor takes our custom `Application` as its only
parameter.

The `Object(...)` line is a little weird for those unfamiliar with GObject and Vala,
but the short of it is that it's Vala's syntax for assigning multiple properties at
once during construction. In this example, we specify the window's application
instance, and a title. Lastly, we tell GTK+ to show the window.

`Application` is similarly short:

{{<highlight vala>}}
public class Application : Gtk.Application {
    public Application() {
        Object(
            application_id: "com.damienradtke.giphy-searcher",
            flags: ApplicationFlags.FLAGS_NONE
        );
    }
}
{{</highlight>}}

`Application` requires two properties to be filled in: a global application id,
and some flags. Note that the application id can be whatever you want, so long
as it's unique. 99% of the time, you'll probably want `FLAGS_NONE` for the
application flags, but there are some behavioral adjustments you can make to
the application as a whole using the [flags](http://valadoc.org/#!api=gio-2.0/GLib.ApplicationFlags).

If you run this application, you should see a window pop up:

{{< figure src="/images/gtk-giphy/gtk-hello-world.png" class="regular" >}}

[1]: /extras/gtk-giphy/1.tar.gz
