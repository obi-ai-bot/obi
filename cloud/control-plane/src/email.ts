// The sign-in emails, through Resend (https://resend.com): its key is a Worker secret.

import type { Env } from "./env";

export interface Mailer {
  send(to: string, subject: string, text: string): Promise<void>;
}

/// No sender is set up, so no code can go out.
export class MailSetupError extends Error {}

export class ResendMailer implements Mailer {
  constructor(
    private readonly key: string,
    private readonly from: string,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  async send(to: string, subject: string, text: string): Promise<void> {
    const response = await this.fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${this.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: this.from, to: [to], subject, text }),
    });
    if (!response.ok) {
      let said = `HTTP ${response.status}`;
      try {
        const body = (await response.json()) as { message?: string };
        if (body.message) said = body.message;
      } catch {
        // Not JSON: the status says enough.
      }
      throw new Error(`The email couldn't be sent: ${said}`);
    }
  }
}

/// Resend from the Worker's secrets, or a sender that says what's missing. With DEV_ECHO_OTP
/// the code comes back in the response and no email is needed.
export function mailerFromEnv(env: Env): Mailer {
  if (env.RESEND_API_KEY) return new ResendMailer(env.RESEND_API_KEY, env.EMAIL_FROM);
  return {
    send: async () => {
      throw new MailSetupError("No email sender is set up: wrangler secret put RESEND_API_KEY, or DEV_ECHO_OTP=true in .dev.vars.");
    },
  };
}
