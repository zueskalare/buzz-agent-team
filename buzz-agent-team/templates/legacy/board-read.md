The board is kept in Buzz issues: one issue is one board item. Only the assistant writes it.

- Where: if this channel is a project home, the board is the project's repository. Otherwise the channel canvas names the board's repository: its owner's public key and its ID. If neither applies, ask the user.
- Read an item with `buzz issues get --event <id>`. List the items with `buzz issues list --repo-owner <hex> --repo-id <id>`.
