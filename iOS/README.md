# Oby for iPhone

The iPhone app is the `ObyPhone` target in `Oby.xcodeproj` (the app is called Oby). It's a client of the **runner**, Oby's engine running as a service on an always-on machine, so the work goes on while the Mac is closed. The contract between them is [`docs/runner-api.md`](../docs/runner-api.md).

What it does today:

- Shows Oby and your jobs live: the step each agent is on, how each one ended, Stop.
- Type a task, check the plan card (agent, model, account, repository, branch), and Dispatch.
- Publish a finished job: Oby shows the exact action, and Face ID signs it with a key that lives in the iPhone's Secure Enclave. Nothing is published without it, and Oby never merges.
- Settings: the runner's address, its accounts, and each tool's model and effort.

## Run it

- **Simulator:** the `ObyPhone` scheme on an iOS 26 or later simulator. Publishing needs a real iPhone, because the simulator has no Secure Enclave.
- **Your iPhone:** connect it, pick it as the destination, and run. It signs with Wellington's personal team until Deskree's team can make certificates. From the command line:

  ```bash
  xcodebuild -project Oby.xcodeproj -scheme ObyPhone -destination 'id=<iPhone UDID>' -allowProvisioningUpdates build
  ```

- **Tests:** `iOSTests`, with `xcodebuild … -scheme ObyPhone -destination '<an iOS 27 simulator>' test`.
- **Reaching the runner:** the iPhone needs Tailscale on. The default runner is `https://tetrix-lab.tail8de49b.ts.net:8443`, and it answers only its owner's Tailscale login.

## Coming next

- A Live Activity and notifications, once the Oby platform can push (F11).
- Talking to Oby, and the Apple Watch app (`Watch/`).
