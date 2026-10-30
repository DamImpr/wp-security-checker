# TODO

Planned work for `wp-security-check`. Items are not in priority order.

- [ ] Extend the notification system beyond the Telegram bot: email and other channels (e.g. Slack, webhooks), selectable from the env file.
- [ ] Add log rotation for the files inside `reports/` (today reports older than 30 days are simply deleted; make the retention configurable and optionally compress old reports).
