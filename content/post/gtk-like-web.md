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
originated. Desktop application stacks, such as GTK (which is the focus of this post), are only
really used as fully client-side applications. Application logic runs directly on the client
machine, and any update requires users to download and install the new version.

In this post, I want to demonstrate a proof-of-concept GTK application using the client-server
deployment model pioneered by the web.

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

However, GTK applications lack the web's deployment model. The web's model is enviable because it
allows applications to receive updates that users don't need to install. As soon as an update is
made live, everyone immediately has access to it (after a refresh, of course).

## Isn't that a whole lot of work, though?

GTK already has support for markup-based rendering in the form of UI files, so we don't have to
build any of the rendering from scratch. This vastly simplifies the work involved, and means that
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

As mentioned earlier, the web consists of both the client-server deployment model that we are
attempting to emulate, and the web frontend technologies used for rendering and scripting. So, in
order to get similar behavior out of a GTK application, we need to find replacements for those:

| Web Technology | Replacement |
|----------|----------|
| HTML   | XML-based UI definitions |
| CSS | CSS |
| JavaScript | Any embeddable scripting language (I've gone with Lua) |

## I'm still not sold.

Well, then let's show a concrete example.

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

## Wait, what's happening here?

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

## That's cool, but the button doesn't seem to do anything.

Yes, that is true; in order for the button to do anything, we need to handle its `clicked` signal.

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

To put this into context, here is what our updated interface description would look like with
scripting:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<interface>
	<!-- Script tags can be placed anywhere, so why not at the top? -->
	<web:script type="lua">
	  print("hello world")
	</web:script>

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
```

## But the button still doesn't do anything.

Yes, I'm getting to that. In order to specify custom `clicked` signal behavior, we first have to
enable custom behavior, which is what we've now accomplished by adding scripting support.

You are right, though, that running scripts is not super useful if we can't interact with the
rendered application. Printing _hello world_ is great and all, but how can we have it wait until the
button is clicked?

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

Now the application won't print _hello world_ when it loads, but will instead show this when you
click the button:

{{< figure src="/images/gtk-like-web/alert.png" class="regular" >}}

## Okay that's pretty cool, but care to explain how that works?

Sure. When we initialize the Lua virtual machine, we register a couple useful things:

1. A custom `Widget` user data type, which defines a `connect()` instance method.
2. A global `find_widget()` function, which takes a widget ID and returns a `Widget` object.
3. A global `alert()` function, which takes a message and displays it in a new dialog.

With a little additional work, other types, methods, and functions can be made accessible to Lua.
Notably, you can also get or set arbitrary GObject properties on widgets, which provides a large
amount of flexibility.

TODO: href linking, CSS styling, form submissions

<!-- vim: set tw=100: -->
