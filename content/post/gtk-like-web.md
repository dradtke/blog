+++
date = "2022-05-18"
title = "Building GTK4 Applications Like Websites"
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

By contrast, the client-server deployment model is not widely used outside of the web in which it
originated. Desktop application stacks, such as GTK (which is the focus of this post), traditionally
only run on the client.

In this post, I want to demonstrate a technique for building GTK applications like they were
websites, using the client-server deployment model.

_For reference, full source code for the prototype, along with examples, can be seen at
https://git.sr.ht/~damien/gtk-webby_

{{< figure src="https://imgs.xkcd.com/comics/installing.png" class="regular" >}}

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

## So you're basically building a new browser?

Kind of. The goal is to have users download a single application that behaves similarly to
browsers, but one that instead renders native GTK interfaces rather than HTML.

(It is worth noting that GTK does support [broadway](https://docs.gtk.org/gtk4/broadway.html), which
allows you to access a running application remotely through your browser, so depending on your needs
it may also be worth checking out, but in this post I'm going for something more native)

So, that's the goal. In order to get there, we need to break it down into (some of) the individual
features provided by your average web browser:

1. [Rendering](#rendering)
2. [Scripting](#scripting)
3. [Linking](#linking)
4. [Styling](#styling)
5. [Submitting Forms](#submitting-forms)
6. [Page Title](#page-title)

After that, I'll end on

7. [Missing Features](#missing-features)
8. [Final Thoughts](#final-thoughts)

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
we need to do to enable styling is extend the UI format to support it.

This example introduces the `web:style` tag, which contains CSS code to apply to the interface:


```xml
<?xml version="1.0" encoding="UTF-8"?>
<interface>
	<!-- This tag contains CSS styles to apply to the rendered
	     application. -->
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

For more information on the specific properties used here, see the CSS property
[documentation](https://docs.gtk.org/gtk4/css-properties.html).

__Note__: The `id` object attribute defines the object ID for Builder access, but it does _not_
actually define the ID for styling. That is actually handled instead by the
[name](https://docs.gtk.org/gtk4/property.Widget.name.html) property. For consistency, the Builder's
ID and the widget name are set to the same value, `body`, but they are separate concepts and are
used for different things.

# Submitting Forms

Forms are a little trickier to introduce to the UI definition. Here is a short example of how you
would build a web form in a browser:

```html
<!-- Example of a simple form in a web browser using HTML -->
<form method="POST">
  <input type="text" name="username" placeholder="username">
  <input type="password" name="password" placeholder="password">
  <input type="submit" value="Log In">
</form>
```

The `form` tag encapsulates a number of `input` tags, and the browser automatically provides a
"submit form" action that is invoked when the submit button is clicked. That action will take the
name and current value from every input tag, encode those into a request body (generally as
`application/x-www-form-urlencoded`), and submit it as an HTTP request with the specified method.

In order to translate this behavior into something GTK-native, we would need to add quite a bit of
logic to our UI parsing code.

A simpler and more flexible solution is to use our existing scripting capabilities. It requires a
little more code, but it doesn't require us to extend the UI format at all, and it's still pretty
easy to see what's going on:

```lua
-- This would be placed inside a <web:script type="lua"> tag.
-- A full example can be seen in Webby's repo at examples/forms/
-- TODO: put a URL
function login()
	local username = find_widget("username"):get_text()
	local password = find_widget("password"):get_text()
	submit_form("POST", "", {username=username, password=password})
end

find_widget("submit"):connect("clicked", false, login)
find_widget("username"):connect("activate", false, login)
find_widget("password"):connect("activate", false, login)
```

The `submit_form()` function takes three arguments:

1. A method, in this case `POST`
2. An action, in this case an empty string, which tells Webby to use the current location
3. A table containing key-value form value pairs

The form data will be encoded the same way a browser would do it, and the result submitted to the
web server.

## Cookie Support

While not strictly related to form processing, Webby's internal HTTP client supports cookies, which
work well with forms that need to save session data. Here are some screenshots from the included
forms example:

{{< figure src="/images/gtk-like-web/login-form-1.png" class="regular" >}}

When this form is submitted, it will make a POST request to `http://localhost:8004/` with the
entered username and password as form fields. After processing, the page will refresh, this time
with cookie session information.

{{< figure src="/images/gtk-like-web/login-form-2.png" class="regular" >}}

# Page Title

A very small, but important feature for user experience on the web is the ability to set the page
title. By default, the current URL is shown as the title, but that's not very readable.

In HTML this is done with a `<title>` tag within a `<head>` tag. For Webby, page metadata is added
using attributes on a `<web:page>` tag:

```xml
<web:page title="Index"/>
```

# Missing Features

Webby is intended to be very simple, and will never attempt to implement the full set of features
available in modern-day web browsers. However, there are a few features that would be very useful,
and potentially worth adding:

1. History, for remembering visited locations
2. Back/Forward buttons
3. Page refresh
4. `src` attributes for scripts and styles
5. GTK version header (sent by Webby on every request indicating the version of GTK it was built
   with, so that servers can react accordingly)
6. Basic authentication

# Final Thoughts

This entire exercise stems from my enjoyment of GTK programming, coupled with my frustration at
shoehorning the web into everything as the One True Platform.

The web's success is not unwarranted, since it is a truly innovative, powerful, and perhaps most
importantly, open platform. However, it is not without its faults. One of the biggest problems with
the web is the sheer size and complexity of its browsers.
[Chromium](https://www.openhub.net/p/chrome/analyses/latest/languages_summary) and
[Firefox](https://www.openhub.net/p/firefox/analyses/latest/languages_summary) both contain over 25
million lines of code; for comparison,
[GTK](https://www.openhub.net/p/gtk/analyses/latest/languages_summary) is under 900k. This
complexity coupled with the web's popularity means that it is a real security concern for sensitive
applications.

Or, for a less serious reason to avoid defaulting to the web for everything: it's more fun to use
something besides HTML and JavaScript. 🤷

While the solution I outline here may not be for everyone, I think there is some real value in
bringing some of the web's lessons to other platforms.

If you made it this far, thanks for reading!

<!-- vim: set tw=100: -->
