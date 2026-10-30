# Test Mode

Test Mode makes the radio transmit synthetic text packets over flood routing so you can exercise repeaters and observers without waiting for real traffic. It is a diagnostic tool for the C6L companion firmware and does not change how normal messages are sent.

## Requirements

- Direct test sends need C6L companion firmware version code 15 or newer, built with `ENABLE_TEST_MODE=1`. Group test sends need version code 16 or newer. The M5Stack Unit C6L USB, BLE, and WiFi test builds enable the feature.
- A connected radio. In the app, open **Settings → Debug → Test Mode**. The tile is disabled when the connected firmware does not support test mode.

Test mode does not survive a reboot. The radio keeps its configuration in RAM only and boots with test mode disabled, an empty path, one-byte short IDs, and an unscoped region. Nothing is written to `NodePrefs`.

## Configuration

| Setting | Meaning |
|---|---|
| Test mode | Master enable. When off, the radio rejects test sends with `ERR_CODE_BAD_STATE`. |
| Short-ID size | Bytes per path hop: 1, 2, or 3. Matches the radio's path hash width. |
| Region | Optional flood region from your saved regions. Choosing **No region** sends unscoped. The app shows the raw 16-byte scope key derived from the region name. |
| Hop path | Space-separated bytes provide a synthetic prefix for the Flood packet. Routers append their own hashes after this prefix. Length must match the short-ID size and leave room for routers to append hops. |
| Randomize path | Keeps the configured hop count and short-ID size but replaces the synthetic prefix bytes for each packet. Routers still append their own hashes. |
| Randomize message | Optional. Selects a short Watch Dogs 2 / DedSec quote for each packet. Turn it off to send the same typed message each time. |
| Randomize sender name | For group packets, optionally generates a new 16-character alphanumeric display name for every packet. Turn it off to use a fixed sender name. |
| Custom timestamp | Use a fixed Unix timestamp instead of the current time. Useful for reproducible captures. |
| Apply settings | Writes the configuration to the radio without sending a packet. |

Pressing **Send test packet** writes the current configuration first, then transmits one Flood packet. The result line reports its region-scoped flood route and the radio's estimated timeout. No ACK is expected or reported for test packets.

## Continuous mode

Continuous mode lets you choose a fixed 250 ms or 500 ms interval. If the radio reports a full packet queue, it waits for the selected interval and retries instead of stopping. Press **Stop** to end it. Each packet gets a fresh random sender and receiver keypair from the radio, so packet hashes and ACK hashes differ even when the text is identical. The last ten successful sends are listed on the screen.

Continuous mode generates constant mesh traffic. Use short runs, especially on shared channels and repeaters. It stops on Stop, leaving the screen, disconnecting, unsupported firmware, or an error/timeout. Error 3 means the radio packet queue is full.

## Wire protocol

The app uses three companion commands, documented in the firmware's `docs/companion_protocol.md`:

| Code | Name | Payload |
|---|---|---|
| 67 | `CMD_TEST_SET_CONFIG` | `[enabled][hash_size][path_byte_len][region_key x16][path bytes]` |
| 68 | `CMD_TEST_GET_CONFIG` | No payload; answered by `RESP_CODE_TEST_CONFIG` |
| 69 | `CMD_TEST_SEND_TXT` | `[timestamp x4 LE][text]`; answered by `RESP_CODE_SENT` (firmware code 15+) |
| 70 | `CMD_TEST_SEND_GROUP_TXT` | `[channel_idx][timestamp x4 LE][sender_len][sender UTF-8][text UTF-8]`; answered by `RESP_CODE_SENT` (firmware code 16+) |

`RESP_CODE_TEST_CONFIG` (30) echoes the configuration in the same layout as the SET payload. Test sends answer with the normal `RESP_CODE_SENT` frame, but the ACK hash is always 0 because no acknowledgement is requested. This lets the app tell a test result apart from a normal message send.

Direct tests build an encrypted `PAYLOAD_TYPE_TXT_MSG` datagram with fresh random sender and receiver identities. Group tests encrypt a `PAYLOAD_TYPE_GRP_TXT` datagram with the selected channel key and prefix the text with a configurable sender display name; group packets have no sender public key. Both modes flood and seed the mutable hop path with the configured prefix; routers append their own hashes after it. An all-zero region key sends unscoped; any other key adds region transport codes while retaining flood routing. The short-ID size controls both the seeded prefix and flood path hash width. See [BLE protocol](ble-protocol.md) and the firmware's protocol guide for the complete framing.
