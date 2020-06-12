# Blog

This repository contains posts hosted at https://damienradtke.com.

## Git Hook Setup

In order to push updates to this blog, it needs to be hosted on a support server, and the `post-receive` hook registered:

```bash
$ git clone --bare @git.sr.ht:~damien/blog blog
$ cd blog
$ ln -s `pwd`/post-receive-deploy.sh .git/hooks/post-receive
```
