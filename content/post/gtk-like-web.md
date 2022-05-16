+++
date = "2022-05-06"
title = "Building GTK Applications Like Websites"
draft = true
+++

The modern web, broadly, consists of two distinct innovations:

1. The technology for __rendering__ and __interacting__ with web pages (also known as the trifecta
   of HTML, CSS, and JavaScript)
2. The client-server __deployment model__, which allows a single desktop application (your web
   browser) to alter its behavior using instructions sent over the network by a web server

Whether you love it or hate it, web rendering and interaction technology is widely used, both on the
web and off. Electron and React Native take the web technology stack and deploy it to your desktop
or phone, respectively, as a standalone application.

By contrast, client-server application deployment is not widely used outside of the web in which it
originated. Desktop application stacks, such as GTK (which is the focus of this post), traditionally
only run on the client.

In this post, I want to demonstrate a technique for building GTK applications like they were
websites, using the client-server deployment model.

## ...but why?

Mainly because web browsers are, first and foremost, document renderers; their role as application
runtimes came much later. JavaScript was famously invented by Brendan Eich in just [10
days](https://thenewstack.io/brendan-eich-on-creating-javascript-in-10-days-and-what-hed-do-differently-today/),
and the rate at which new frameworks are released has caused many developers to suffer from
[JavaScript fatigue](https://auth0.com/blog/how-to-manage-javascript-fatigue/). This deluge of
frontend frameworks largely stems from browsers being designed back in the 90's to do one thing, and
now being used to do so much more. By contrast, development stacks such as GTK were designed to run
applications from the start, and as a result, come with many useful features that web applications
need to either build from scratch, or import from a third-party library.

However, GTK applications lack the web's flexibility. When an update is made to a GTK application,
all users need to download the update and install it; when an update is made to a web application,
it does not require any installation, and the changes are immediately available for all possible
clients (after a refresh, of course).

Also, GTK already has support for markup-based rendering in the form of UI files, so we don't have
to build any of the rendering from scratch. This vastly simplifies the work involved, and means that
the task is mostly one of gluing together existing components, rather than building something new.

<!--
As an aside: the intended audience of this post is, primarily, teams that are building internal
applications as part of their tooling. While there is no technical reason that this technology
couldn't be used for consumer-facing applications, it is unrealistic to expect your average consumer
to download a separate "browser" with minimal features to access certain "websites." However, for
teams with relatively little web development experience that want to build internal applications,
the approach I outline here ensures that everyone is running the latest version, and users will only
have to download the client application once.
-->

## So you're basically building a new browser?

Kind of. The goal is to have users download a single application that behaves similarly to
browsers, but one that instead renders native GTK applications.

(It is worth noting that GTK does support [broadway](https://docs.gtk.org/gtk4/broadway.html), which
allows you to access a running application remotely through your browser, but that has several
downsides: no automatic session management, reliance on websockets, and still requires the use of an
existing web browser. Plus my way is more fun)

So, that's the goal. In order to get there, we need to break it down into (some of) the individual
features provided by your average web browser:

1. [Rendering](#rendering)
2. [Scripting](#scripting)
3. [Linking](#linking)
4. [Styling](#styling)
5. [Submitting forms](#submitting-forms)
6. Miscellaneous (page title)

# Rendering

The most basic, fundamental feature we need is the ability to render an application. In order to do
that, we first need a canvas:

{{< figure src="/images/gtk-like-web/webby.png" class="regular" >}}

This is Webby, the current name of my proof-of-concept, built with [gtk-rs](https://gtk-rs.org/).

When you first launch it, it doesn't look like much, but that's because it's an empty shell. In
order to get it to do something, we need to also build a web application that we can access.

Sticking with our Rust theme, we can build one pretty quickly using Rocket:

```rust
#[macro_use] extern crate rocket;

#[get("/")]
fn index() -> &'static str {
    return r#"
        <?xml version="1.0" encoding="UTF-8"?>
        <interface>
            <object class="GtkBox" id="body">
                <property name="orientation">vertical</property>
                <property name="halign">start</property>
                <child>
                    <object class="GtkButton">
                        <property name="label">Click Me</property>
                    </object>
                </child>
            </object>
        </interface>
    "#;
}

#[launch]
fn rocket() -> _ {
    rocket::build().mount("/", routes![index])
        .configure(rocket::Config{
            port: 8000,
            ..Default::default()
        })
}
```

With this running, we can now navigate to `http://localhost:8000/` and see what we get:

{{< figure src="/images/gtk-like-web/webby-hello.png" class="regular" >}}

In a nutshell, here is what's happening:

1. We are making a GET request to `http://localhost:8000/`, which returns the user interface
   definition returned by our Rocket application.
2. The body of the request is parsed by a GTK
   [Builder](https://docs.gtk.org/gtk4/class.Builder.html), which will instantiate all of the
   described objects.
3. We look for a [Widget](https://docs.gtk.org/gtk4/class.Widget.html) object with id `body` (here
   it is an instance of [Box](https://docs.gtk.org/gtk4/class.Box.html)).
4. That `body` widget is set as the child of Webby's content area, which is simply a
   [ScrolledWindow](https://docs.gtk.org/gtk4/class.ScrolledWindow.html) instance.

GTK Builders are very powerful, so this is all that we need in order to properly render an interface
of basically arbitrary complexity. By using [Glade](https://glade.gnome.org/), you can pretty
quickly build fairly complex interfaces, and anything contained within a `body` widget will be
rendered by Webby.

In order to really do something with this, we need to introduce some additional features.

# Scripting

Continuing with the example above, in order for the button to do anything, we need to handle its
`clicked` signal.

The Builder way of doing this would be to define a `<signal>`
[element](https://docs.gtk.org/gtk4/class.Builder.html#signal-handlers-and-function-pointers), but
that requires that your handler be defined within the application, and frankly I'm not sure how that
works when not using GTK's native C.

The web's solution here is to introduce scripting (where JavaScript comes in), which allows the web
server to specify client-side behavior. We can do something similar by bringing in an embeddable
scripting language. I've chosen Lua because it's relatively simple and easy to embed, though Webby
theoretically can support other languages too, even
[JavaScript](https://github.com/denoland/rusty_v8) itself if you really want to.

Now, the big caveat here is that the GTK UI interface format was not designed to support scripting,
or frankly to mimic the web. So in order to support scripting, we will need to "extend" the format
to support what we need.

To recap, here is how you would define client-side behavior for a regular web application:

```html
<script type="text/javascript">
  console.log("hello world");
</script>
```

The approach taken by Webby is very similar:

```xml
<web:script type="lua">
  print("hello world")
</web:script>
```

There are a couple key differences here:

1. Webby uses a `web:` prefix to identify tags that are considered extensions to the UI format. When
   loading an interface description, Webby will strip out any tag with this prefix before passing it
   to the Builder, since it will throw an error when it encounters an unrecognized tag. There are a
   few supported `web:` tags (more on that later), and `web:script` is used to indicate the presence
   of a script that should be executed.
2. The `type` attribute is required, and specifies the name of the scripting language in a plain,
   non-MIME format. Only `lua` is supported, but this provides an easy extension point for adding
   new languages.

Using this capability, here is how we might connect a signal handler to our button:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<interface>
	<!-- Script tags can be placed anywhere, so why not at the top? -->
	<web:script type="lua">
	  button = find_widget("click-me")
	  button:connect("clicked", false, function()
	  	alert("hello world")
	  end)
	</web:script>

    <object class="GtkBox" id="body">
        <property name="orientation">vertical</property>
        <property name="halign">start</property>
        <child>
            <object class="GtkButton" id="click-me">
                <property name="label">Click Me</property>
            </object>
        </child>
    </object>
</interface>
```

Now when we click the button, we get this:

{{< figure src="/images/gtk-like-web/alert.png" class="regular" >}}

Neat! In order to facilitate this, we need to initialize the Lua virtual machine with a few things:

1. Two global functions: `alert()` and `find_widget()`.
2. A custom `Widget` user data type, which is returned by `find_widget()`.
3. A `connect()` method on the `Widget` type.

Other functions are available as well (notably `widget:get_property()` and `widget:set_property()`),
so there's quite a bit of flexibility in what you can do.

# Linking

One common, but simple feature supported by websites is the ability to link to other pages. In order
to support that use-case, Webby adds support for a custom attribute for buttons (and theoretically,
any widget that supports the `clicked` signal):

```xml
<object class="GtkButton" web:href="/about">
	<property name="label">About</property>
</object>
```

The `web:href` attribute specifies a URL, either relative or absolute, and will tell Webby to
automatically configure a `clicked` signal handler that will tell Webby to navigate to the requested
URL.

# Styling

Just like the web, GTK supports CSS [natively](https://docs.gtk.org/gtk4/css-overview.html), so all
we need to do to enable styling is extend the UI format to support it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<interface>
	<!-- This tag is analgous to HTML's <style> tag -->
	<web:style>
		#body {
			font-size: x-large;
		}

		.red {
			color: shade(red, 1.6);
		}

		.blue {
			color: shade(blue, 1.6);
		}
	</web:style>

	<object class="GtkBox" id="body">
		<property name="orientation">vertical</property>
		<property name="halign">start</property>
		<property name="name">body</property> <!-- the 'name' property defines the CSS ID -->
		<child>
			<object class="GtkLabel">
				<style><class name="red"/></style>
				<property name="label">This line is red,</property>
			</object>
		</child>
		<child>
			<object class="GtkLabel">
				<style><class name="blue"/></style>
				<property name="label">and this one is blue!</property>
			</object>
		</child>
	</object>
</interface>
```

Here is the rendered result:

{{< figure src="/images/gtk-like-web/styling.png" class="regular" >}}

__Note__: The `id` object attribute defines the object ID for Builder access, but it does _not_
actually define the ID for styling. That is actually handled instead by the
[name](https://docs.gtk.org/gtk4/property.Widget.name.html) property. For consistency, the Builder's
ID and the widget name are set to the same value, `body`, but they are separate concepts and are
used for different things.

# Submitting Forms

<!-- vim: set tw=100: -->
