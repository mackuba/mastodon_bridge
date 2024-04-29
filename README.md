## mastodon_bridge

This project is an experiment in creating a proxy that lets you view the timeline of your Mastodon account inside Bluesky app (the official one or some other) as a "virtual" custom feed. It's supposed to be kind of like a reverse [SkyBridge](https://skybridge.fly.dev), bridging things in the other direction. (Somewhat inspired also by the SkyFeed [bridge-proxy](https://github.com/skyfeed-dev/bridge-proxy) project.)

Most requests are proxied to the real PDS, while a `getFeed` request for a specific "Mastodon" feed is instead handled by making a request to the Mastodon API and converting the returned posts, making it seem as if they are real ATProto post records.
