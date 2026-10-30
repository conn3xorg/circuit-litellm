# Local example

Applies circuit-litellm to a throwaway Rocky Linux 10 container with systemd, with [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) and [circuit-presidio](https://github.com/conn3xorg/circuit-presidio) on the same host. A Presidio guardrail masks names and email addresses in every request before it reaches a model. You need Conn3x and Podman.

LiteLLM runs under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs PostgreSQL and Podman, pulls LiteLLM's and Presidio's images and waits while LiteLLM sets up its database. The second plan says `No changes.` The example's database password is a default in `main.tf`, which you'd never keep on a real host.

The example has two models, `small` and `large`, and no real provider behind them. Both point at `127.0.0.1:9999`, where CI runs a stand-in that answers like OpenAI's API, so no API key is needed. To talk to a real model, change `models` and `api_keys` in `main.tf`, as in the [main README](../../README.md#usage).

LiteLLM listens on `127.0.0.1:4000` inside the container. Its image has no curl, but it has Python, so to ask it something:

```sh
ssh -p 2304 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  podman exec litellm python -c \
  "'import urllib.request; print(urllib.request.urlopen(\"http://127.0.0.1:4000/health/liveliness\").read())'"
```

The answer is `b'"I\'m alive!"'`. The master key for the key API is in `/etc/litellm/keys.env` in the container; see [Keys for teams and people](../../README.md#keys-for-teams-and-people).

`up.sh` listens on `127.0.0.1:2304`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
