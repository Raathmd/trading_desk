defmodule TradingDesk.Emails.MagicLinkEmail do
  @moduledoc """
  Builds the magic link login email sent to the trader.
  """

  import Swoosh.Email

  @from_name  "NH3 Trading Desk"
  @from_email "noreply@trammo.com"

  @doc """
  Builds a Swoosh.Email struct for the magic link.
  """
  @spec build(String.t(), String.t()) :: Swoosh.Email.t()
  def build(to_email, login_url) do
    new()
    |> to({to_email, to_email})
    |> from({@from_name, @from_email})
    |> subject("Your NH3 Trading Desk login link")
    |> html_body(html_body(login_url))
    |> text_body(text_body(login_url))
  end

  defp html_body(url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width,initial-scale=1"/>
    </head>
    <body style="margin:0;padding:0;background:#040810;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif">
      <table width="100%" cellpadding="0" cellspacing="0" style="background:#040810;padding:40px 20px">
        <tr><td align="center">
          <table width="480" cellpadding="0" cellspacing="0" style="background:#0d1526;border:1px solid #1e293b;border-radius:12px;overflow:hidden">

            <!-- Header -->
            <tr>
              <td style="background:#080c14;padding:20px 32px;border-bottom:1px solid #1b2838">
                <span style="font-size:11px;font-weight:700;letter-spacing:2px;color:#38bdf8">TRAMMO · NH3 DESK</span>
              </td>
            </tr>

            <!-- Body -->
            <tr>
              <td style="padding:32px">
                <h1 style="margin:0 0 8px;font-size:22px;font-weight:800;color:#f8fafc">Your login link</h1>
                <p style="margin:0 0 24px;font-size:14px;color:#7b8fa4;line-height:1.6">
                  Click the button below to securely access the NH3 Trading Desk.
                  This link is single-use and does not expire.
                </p>

                <table cellpadding="0" cellspacing="0" style="margin-bottom:24px">
                  <tr>
                    <td style="border-radius:8px;background:linear-gradient(135deg,#0ea5e9,#2563eb)">
                      <a href="#{url}"
                         style="display:inline-block;padding:14px 28px;font-size:14px;font-weight:700;color:#ffffff;text-decoration:none;letter-spacing:0.5px">
                        Open Trading Desk →
                      </a>
                    </td>
                  </tr>
                </table>

                <p style="margin:0 0 8px;font-size:12px;color:#475569">
                  Or copy this URL into your browser:
                </p>
                <p style="margin:0;font-family:monospace;font-size:11px;color:#94a3b8;word-break:break-all;background:#060c16;padding:10px 12px;border-radius:6px;border:1px solid #1e293b">
                  #{url}
                </p>
              </td>
            </tr>

            <!-- Footer -->
            <tr>
              <td style="padding:16px 32px;border-top:1px solid #1b2838">
                <p style="margin:0;font-size:11px;color:#475569;line-height:1.6">
                  This link was requested for your Trammo email address.
                  If you did not request it, you can safely ignore this email.
                  Do not forward this link to anyone.
                </p>
              </td>
            </tr>

          </table>
        </td></tr>
      </table>
    </body>
    </html>
    """
  end

  defp text_body(url) do
    """
    TRAMMO · NH3 TRADING DESK

    Your login link:
    #{url}

    This link is single-use and does not expire.
    If you did not request it, ignore this email.
    """
  end
end
