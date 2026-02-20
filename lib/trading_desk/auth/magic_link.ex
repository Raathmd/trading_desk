defmodule TradingDesk.Auth.MagicLink do
  @moduledoc """
  Magic link authentication for the private trading desk.

  Only allowlisted email addresses can request a login link.
  Tokens expire after 1 hour and are single-use.

  Rate limiting: if a token was generated less than 5 minutes ago for the
  same email, the same token is reused and :rate_limited is returned so
  the UI shows a generic "check your inbox" message without leaking timing.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias TradingDesk.Repo
  alias TradingDesk.Auth.User

  require Logger

  # Token TTL — effectively permanent until used (100 years)
  # Change this if expiry is needed in future.
  @token_ttl_seconds 100 * 365 * 24 * 3600

  # Rate-limit window in seconds (5 minutes)
  @rate_limit_seconds 300

  schema "magic_link_tokens" do
    field :email,      :string
    field :token,      :string
    field :expires_at, :utc_datetime
    field :used_at,    :utc_datetime
    timestamps()
  end

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Returns all authorised email addresses from the users table, sorted."
  @spec list_emails() :: [String.t()]
  def list_emails do
    Repo.all(from u in User, select: u.email, order_by: u.email)
  end

  @doc "Returns true if the email exists in the users table."
  @spec allowed?(String.t()) :: boolean()
  def allowed?(email) when is_binary(email) do
    Repo.exists?(from u in User, where: u.email == ^String.downcase(String.trim(email)))
  end
  def allowed?(_), do: false

  @doc """
  Generate a single-use magic link token for the given email.

  Rate-limited: if a valid unused token was generated within the last
  #{@rate_limit_seconds} seconds, returns {:error, :rate_limited} — the
  caller should show the same "check your inbox" message as a success to
  avoid leaking timing information.

  Returns:
    {:ok, token_string}     — new token created, send the link
    {:error, :rate_limited} — existing token still fresh, do not re-send
    {:error, :not_allowed}  — email not on allowlist
    {:error, :db_error}     — unexpected DB failure
  """
  @spec generate(String.t()) :: {:ok, String.t()} | {:error, :rate_limited, String.t()} | {:error, atom()}
  def generate(email) do
    email = String.downcase(String.trim(email))

    if allowed?(email) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      rate_limit_cutoff = DateTime.add(now, -@rate_limit_seconds, :second)

      # Check if a fresh token already exists (rate limiting)
      existing =
        Repo.one(
          from t in __MODULE__,
            where: t.email == ^email and is_nil(t.used_at) and t.inserted_at > ^rate_limit_cutoff,
            order_by: [desc: :inserted_at],
            limit: 1
        )

      if existing do
        Logger.info("Magic link rate-limited for #{email} — existing token still valid")
        {:error, :rate_limited, existing.token}
      else
        # Purge all previous tokens for this email
        Repo.delete_all(from t in __MODULE__, where: t.email == ^email)

        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        expires_at = DateTime.add(now, @token_ttl_seconds, :second)

        changeset =
          %__MODULE__{}
          |> cast(%{email: email, token: token, expires_at: expires_at}, [:email, :token, :expires_at])
          |> validate_required([:email, :token, :expires_at])

        case Repo.insert(changeset) do
          {:ok, _} ->
            Logger.info("Magic link token generated for #{email}")
            {:ok, token}

          {:error, cs} ->
            Logger.error("Failed to generate magic link token: #{inspect(cs.errors)}")
            {:error, :db_error}
        end
      end
    else
      {:error, :not_allowed}
    end
  end

  @doc """
  Verify a token. If valid, marks it as used and returns the email.

  Returns {:ok, email} | {:error, :invalid | :expired | :already_used}
  """
  @spec verify(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(__MODULE__, token: token) do
      nil ->
        {:error, :invalid}

      %__MODULE__{used_at: used} when not is_nil(used) ->
        {:error, :already_used}

      %__MODULE__{expires_at: exp} = record ->
        if DateTime.compare(exp, now) == :gt do
          record |> change(used_at: now) |> Repo.update!()
          Logger.info("Magic link used for #{record.email}")
          {:ok, record.email}
        else
          {:error, :expired}
        end
    end
  end

  def verify(_), do: {:error, :invalid}

  @doc """
  Clean up expired and used tokens older than 24 hours.
  """
  @spec purge_old_tokens() :: {integer(), nil}
  def purge_old_tokens do
    cutoff = DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.truncate(:second)
    Repo.delete_all(from t in __MODULE__, where: t.inserted_at < ^cutoff)
  end
end
