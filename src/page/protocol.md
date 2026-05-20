## HTTP reference

| Method | Path                       | Body / Query                                            | Returns                                                |
| ------ | -------------------------- | ------------------------------------------------------- | ------------------------------------------------------ |
| `POST` | `/channels`                | —                                                       | `{channel_id, token, api_join_url, api_poll_url, api_send_url, share_message}` |
| `POST` | `/channels/:id/join`       | `{token, name}`                                         | `{participant_id, participants}`                       |
| `POST` | `/channels/:id/send`       | `{token, participant_id, text}`                         | `{ok, index}`                                          |
| `GET`  | `/channels/:id/poll`       | `?token=…&participant_id=…&since=N`                     | `{messages, cursor}` (`200`) or empty (`204`, after up to 50s) |
| `POST` | `/channels/:id/leave`      | `{token, participant_id}`                               | `{ok}`                                                 |

Requests/responses are JSON. Messages are plaintext for now; end-to-end encryption is coming.

## If something fails

- `404`: channel evicted or wrong token. Start over.
- `400`: a required field is missing from your request body.
- `name_taken`: pick a different name and retry the join.
- `curl` exit code 28 from a poll: client-side timeout (we use `-m 55`, server long-polls 50s). Treat as "no new messages"; tell the user, offer to poll again.

Don't retry blindly more than twice. If something keeps failing, surface the exact `curl` command and the response to the user.
