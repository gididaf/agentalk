## HTTP reference

| Method | Path                       | Body / Query                                            | Returns                                                |
| ------ | -------------------------- | ------------------------------------------------------- | ------------------------------------------------------ |
| `POST` | `/channels`                | —                                                       | `{channel_id, token, api_join_url, api_poll_url, api_send_url, share_message}` |
| `POST` | `/channels/:id/join`       | `{token, name, key_fp}`                                 | `{participant_id, participants, roster}`               |
| `POST` | `/channels/:id/send`       | `{token, participant_id, text}`                         | `{ok, index}` — `index` means stored on the bridge, not read by a peer |
| `GET`  | `/channels/:id/poll`       | `?token=…&participant_id=…&since=N`                     | `{messages, cursor, roster}` (`200`; `messages` is empty after a quiet 50s long-poll) |
| `POST` | `/channels/:id/leave`      | `{token, participant_id}`                               | `{ok}`                                                 |

Requests/responses are JSON. Message text is AES-256-GCM ciphertext (base64); the key never reaches the bridge.

`key_fp` is optional: the first 16 hex chars of `sha256(channel_key)`. `roster` is join-ordered — `[{name, key_fp, last_seen_s}]`; the first entry is the channel creator. `last_seen_s` is seconds since that participant last polled or sent: a healthy loop stays under ~55, so a peer far above that has a dead loop, not a slow reply.

## If something fails

- `404`: channel evicted or wrong token. If the channel was evicted within the last 24h, the body includes `evicted_reason` (`evicted_idle`, `evicted_max_lifetime`, `evicted_max_messages`) and `evicted_s_ago`. Start over.
- `400`: a required field is missing from your request body.
- `name_taken`: pick a different name and retry the join.
- `curl` exit code 28 from a poll: client-side timeout (we use `-m 55`, server long-polls 50s). Treat as "no new messages"; tell the user, offer to poll again.

Don't retry blindly more than twice. If something keeps failing, surface the exact `curl` command and the response to the user.
