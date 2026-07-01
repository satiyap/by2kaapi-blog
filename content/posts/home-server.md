+++
date = '2026-05-24T21:05:19+05:30'
draft = false
title = 'Home Server: From an Empty Pi to a Self-Deploying Cluster'
+++

Been playing with AI since Q2 2025, and one thing that was exciting initially was you can experiment and ship things quickly - they almost looked fully baked. At that time, I was getting basic apps out and this just felt like magic.

I had been picking up subscriptions for supabase, vercel, claude, chatgpt; things were getting expensive ... those $20 really add up. I did not want to spend on server so, I figured I might as well pull out the rpi and set things up locally instead. Some of these; eventually had to keep running long-term ... that was the thinking at the time.

A year on, that Pi is a single-node Kubernetes cluster that I have setup a deployment pipeline on, it picks up changes from my Github and auto deploys, serves real HTTPS to my LAN. In retrospect, this is the best investment of a weekend.

Stuff that AI tripped up (atleast at the time); it is really interesting how things have gotten really good! 

- Browser-trusted SSL even on LAN. No browser warnings, nothing feels half-done when making things public, and with just a DNS change, you can technically go public - everything just works.
- A solid handle on DNS pays off. Point a public hostname at a private IP and skip the whole reverse-proxy / private-DNS layer.
- Same with IP and TCP. Once you can picture the packet flow, most reachability questions answer themselves, both when wiring stuff up and when it breaks. This had to do with how my rpi was not reachable over WiFi
- With AI, living dangerously was evident. push to `main`, ~6 minutes later it's running. You break it, you find out fast, you fix it faster. GitHub Actions does the build, Flux does the rest
- K3s instead of full Kubernetes - this was probably strange, perhaps i should have run lighter workloads on my rpi but it was good learning. It saved my ~0.5 GB ram I think.Whole binary is ~70 MB. Works for what I actually do: my experiments churn out a new app most weeks, they all share one rpi. 
- Quick `kubectl` hacks and Flux + `prune: true` resets the cluster to homeserver repo on Github was a lifesaver. The mess never sticks. It was worth the time it took to find the right tool for this (well, it was new to me atleast).
- [sops](https://github.com/getsops/sops) +  [age](https://github.com/filosottile/age) was good, as encrypted secrets can be safely committed to Github repo. I ended up using secrets manager for stuff that was public facing, but this was good initially.
- Adding a second node later was seamless.

## Hardware and networking

The home server runs on a Raspberry Pi 5 with 16 GB RAM, an NVMe SSD on a HAT, and wired Ethernet. One thing that became important very early was giving the Pi a stable LAN address through a DHCP reservation. In practice, that stable IP became the anchor point for the rest of the setup. Everything else on the network only needed to know where the Pi lived.

I initially ran into some hostname resolution issues, so I also added a separate Raspberry Pi running Pi-hole. It is not part of the cluster; it simply acts as the LAN’s DNS resolver and gives me a convenient place to keep local DNS records. The rest of Pi-hole’s capabilities were more of an accidental bonus than the original goal.

For the server OS, I went with Debian 13 (trixie) for arm64 rather than Raspberry Pi OS. This switch made things a little easier, although it could just be that I had already made enough mistakes along the way and Pi OS would have been fine. At idle, the machine uses roughly 4 GB of RAM and a small slice of disk, leaving plenty of headroom for the services I want to run.

The network itself is intentionally simple. The router handles DHCP and NAT, and everything runs on a flat home LAN. At this stage, nothing in the setup is reachable from the public internet.

The part I deliberately avoided was maintaining a separate private DNS setup. I use a real domain managed through Cloudflare, and each internal service gets a DNS record that points to the Pi’s private LAN address. From outside my home network, the name may resolve, but the connection does not go anywhere useful because private IP ranges are not routable on the public internet.

That simplicity has a few nice side effects. There is no split-horizon DNS, no separate reverse-proxy box, and no edge gear to manage. Cloudflare hands out the name, the name resolves to a private address, and only devices already on the LAN can actually reach it.

## K3s, TLS, and GitOps

The cluster is a single-node K3s setup running on the Pi. The install is standard, most models handle this seamlessly.

There are some decisions you will have to make (only because the number of options are plenty). In my setup, i got Traefik to bind on ports 80 and 443 on the pi.  Traefik does the routing based on the host header.

Traefik is managed by K3s as a `HelmChart` so  add a `HelmChartConfig` and let K3s merge your values into the managed chart. I use this to

* binds Traefik to host ports 80 and 443
* disables the extra LoadBalancer service
* redirects HTTP to HTTPS at the entrypoint
* terminate TLS on traefik; trafeik <--http--> pod

### TLS on the LAN

The services use real domain names and real Let’s Encrypt certificates on LAN (just to sort out the headers / https handing at early stage)

* DNS-01 validation using cert-manager allows LetsEncrypt certs to be issued and rotated seamlessly by creating a temporary TXT record in DNS.
*  the domain is on Cloudflare (you will need a real domain for this and zones available publicly)
* renewals happen automatically. I have not had to touch certificates by hand since setting this up.

Create a CF token with narrow scope: zone read and DNS edit for one zone only (not sure if this can be further narrowed down to just TXT records). 

### GitOps with Flux

After the first few, YAML config was getting a little messy. Looked for a solve and in came Flux. Everything after the base K3s install lives in Git, and Flux keeps the cluster aligned with the repo (cluster repo).

The workflow is simple; if you need a change to the cluster or deploy new apps:

1. Push to `main`
2. Flux pulls the repo
3. Flux applies the diff
4. Anything that drifts gets corrected
5. This is same pattern as updates to apps.

### Kustomize and secrets

Each directory has a small Kustomize file listing what Flux should apply. This is still one cluster, so the configs are simple right now. If I add another node or another environment later, overlays may start to make sense.

Secrets live in the same repo, but encrypted with SOPS and age. The convention is simple: files matching `*.secret.yaml` are encrypted before commit. Only the secret values are encrypted; names, namespaces, and resource types stay readable, which keeps diffs useful.

Flux has the age private key inside the cluster and decrypts secrets at apply time. The repo stays safe to lose, and the cluster can still be rebuilt from Git.

## Auto-deploys: from `git push` to running pod

The cluster repo manages the cluster. Application code lives in separate repos. Flux image automation connects the two.

The pattern is simple. When an app repo builds a new container image and pushes it to GHCR, Flux notices the new image tag, updates the deployment manifest in the cluster repo, commits that change, and then reconciles the cluster.

For each app that auto-deploys, I use three Flux resources:

* `ImageRepository` watches the container registry for new image tags.
* `ImagePolicy` decides which tag should be deployed.
* `ImageUpdateAutomation` writes the selected tag back into the cluster repo.

I have setu;p the GitHub Actions (it need not be Github, most providers give you some[^ci] capability to run pipelines) workflow to only manage the build:

1. build the image
2. tag it with the branch, timestamp, and commit SHA
3. push it to GHCR (you can replace this with any container registry)

The GitHub runner does not talk to Kubernetes. It does not run `kubectl apply`. It does not even need to know where the cluster is. Its job ends after pushing the image.

Flux handles the rest from inside the cluster.

The tag format I use is timestamp-based, so selecting the latest image is deterministic. Flux polls the image registry, picks the newest valid tag, updates the deployment YAML, and commits the change back to the cluster repo. The deployment manifest has Flux image markers that tell it exactly which image line it is allowed to rewrite.

In practice, the delay from `git push` to a running pod is a few minutes. The registry poll is the slowest part. I use `IfNotPresent` for the image pull policy because every deploy gets a new tag; the tag change itself is enough to trigger the rollout.

The best part is the audit trail. Every deployment becomes a real Git commit in the cluster repo. The diff shows exactly which image changed, the tag points back to the application commit, and the cluster state remains explainable from Git.

So “what is running right now?” is not a Kubernetes archaeology exercise. It is just a Git log.


## Headlamp: in-cluster dashboard

K3s ships with no dashboard. I just wanted a little insight into what is going on. This was very interesting, gives pretty good visualizations.

The login for this is an absolute disaster. Also post login flow, user has full control of the cluster; i would have preferred something that is read only. I will spend sometime to hook this up with supertokens (should be feasible)

## Dozzle: live logs

This was again a life-saver! I was for the lack of better way to say this - too used to the Coralogix / Datadog. This was a great find; gives me just enf information, and i have the most important thing sorted with this setup - ability to quickly figure out what is going wrong in the different projects that are running on my setup.

Could this have been sorted with better grasp on grep? .. perhaps. But I like this comfort for sure; highly recommend Dozzle. It gives my a good view of everything happening across my entire setup at a glance. Till I move observability to a fully agentic system, the visualization gives me comfort I guess.

Dozzle doesn't store any logs. In Kubernetes mode it reads through from kubectl logs. It's a viewer, not a logs sink. Doesn't eat into my limited disk space.

For real retention something like Loki + Promtail (or Vector), which is an overkill for me and I've never actually needed it. Live tailing (and the visual comfort) covers ~99% of what I need.

## What's actually running

Reality check, since I've been talking abstractly. Right now on this Pi:

- **`kube-system`**: Traefik, CoreDNS, metrics-server, local-path storage provisioner.
- **`cert-manager`**: controller, webhook, cainjector.
- **`flux-system`** runs six controllers: source, kustomize, helm, notification, image-reflector, image-automation.
- **`shared-services`**: Postgres 16 StatefulSet on a 10 Gi PVC, SuperTokens (self-hosted auth talking to Postgres).
- **`headlamp`**: one pod, the dashboard.
- **`dozzle`**: one pod, the log viewer.
- **`firefly`**: a personal-finance app; tracks my expenses.
- **`koolaid`**: agentic memory that I built in Sep 25. Works for tracking chores, things I said I will do etc; Available as an MCP, use this regularly. Might prefer moving to one of the maintained frameworks. The learnings were good from building this.

Twenty-something pods total. Memory pressure is basically nil. The Pi handles all of it without breaking a sweat. I think it costs me about ₹170 in electricity bills, this investment should now be at net 0 soon.

## Where it's at

Right now, the Pi is:

- A single-node K3s cluster on Debian, static LAN IP.
- Reconciling itself from a Git repo on a one-minute interval, with a dependency-ordered Kustomization chain.
- TLS for all services it runs; Traefik manages the HTTP→HTTPS redirect.
- Polling ghcr for new image tags and writing its own deploy commits back to the cluster repo.
- Manageable through a browser-based dashboard at `headlamp`, with live multi-pod log tailing at `dozzle`.

I did end up adding a second node, its where this blog is hosted. I think i need to resolve some issues related to the setup; ill probably write a follow up

## Things I'd do in future

Short list of things that did not sit well. This could be mis-configuration as well.

- move away from pasting service account token on `headlamp` login screen. This kinda beats the point of, i could just be misconfiguring this. The token expires every 24hrs (could be a security consideration too, not sure)
- I use tailscale, want to replace that with headscale. But in general, I am paranoid to open any ports on LAN; this will take some time to understand.

[^ci]: Depends, sometimes this is behind a paid tier.
