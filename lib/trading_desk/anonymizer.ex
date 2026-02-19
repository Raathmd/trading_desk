defmodule TradingDesk.Anonymizer do
  @moduledoc """
  Anonymizes sensitive commercial data (counterparty names, vessel names, contract
  numbers) before sending to external AI APIs, and de-anonymizes the response.

  The trading desk handles commercially sensitive data — counterparty names, SAP
  contract references, and cargo details must not be sent in identifiable form to
  external APIs.

  ## How it works

  1. Build an `anon_map` from the sensitive names in your data.
  2. Call `anonymize/2` to replace real names with codes (ENTITY_01, VESSEL_01, etc.).
  3. Send the anonymized text to the external API.
  4. Call `deanonymize/2` on the response to restore real names.

  ## Example

      iex> names = ["Mosaic Company", "NGC Trinidad", "Koch Fertilizer"]
      iex> {anon_text, anon_map} = Anonymizer.anonymize("Ship to Mosaic Company", names)
      iex> anon_text
      "Ship to ENTITY_01"
      iex> Anonymizer.deanonymize("ENTITY_01 needs 5000 MT", anon_map)
      "Mosaic Company needs 5000 MT"
  """

  @doc """
  Anonymize a list of sensitive names within a text string.

  Returns `{anonymized_text, decode_map}` where `decode_map` maps
  generated codes back to the original names.

  Names are sorted longest-first to prevent partial-match shadowing.
  """
  @spec anonymize(String.t(), [String.t()]) :: {String.t(), map()}
  def anonymize(text, real_names) when is_binary(text) and is_list(real_names) do
    # Deduplicate, filter empty, sort longest-first to avoid partial matches
    sorted =
      real_names
      |> Enum.uniq()
      |> Enum.reject(&(&1 == nil or String.trim(&1) == ""))
      |> Enum.sort_by(&String.length/1, :desc)

    {anon_text, decode_map, _idx} =
      Enum.reduce(sorted, {text, %{}, 1}, fn name, {acc_text, acc_map, idx} ->
        if String.contains?(acc_text, name) do
          code = next_code(name, idx)
          {String.replace(acc_text, name, code), Map.put(acc_map, code, name), idx + 1}
        else
          {acc_text, acc_map, idx}
        end
      end)

    {anon_text, decode_map}
  end

  @doc """
  Anonymize multiple text strings using the same name list.

  Returns `{[anonymized_texts], decode_map}`.
  """
  @spec anonymize_many([String.t()], [String.t()]) :: {[String.t()], map()}
  def anonymize_many(texts, real_names) when is_list(texts) and is_list(real_names) do
    sorted =
      real_names
      |> Enum.uniq()
      |> Enum.reject(&(&1 == nil or String.trim(&1) == ""))
      |> Enum.sort_by(&String.length/1, :desc)

    {anon_texts, decode_map, _} =
      Enum.reduce(sorted, {texts, %{}, 1}, fn name, {acc_texts, acc_map, idx} ->
        if Enum.any?(acc_texts, &String.contains?(&1, name)) do
          code = next_code(name, idx)
          new_texts = Enum.map(acc_texts, &String.replace(&1, name, code))
          {new_texts, Map.put(acc_map, code, name), idx + 1}
        else
          {acc_texts, acc_map, idx}
        end
      end)

    {anon_texts, decode_map}
  end

  @doc """
  Restore original names in a text string using the decode map.
  """
  @spec deanonymize(String.t(), map()) :: String.t()
  def deanonymize(text, decode_map) when is_binary(text) and is_map(decode_map) do
    Enum.reduce(decode_map, text, fn {code, real}, acc ->
      String.replace(acc, code, real)
    end)
  end

  def deanonymize(nil, _), do: nil
  def deanonymize(text, _), do: text

  @doc """
  De-anonymize a list of strings.
  """
  @spec deanonymize_list([String.t()], map()) :: [String.t()]
  def deanonymize_list(list, decode_map) when is_list(list) do
    Enum.map(list, &deanonymize(&1, decode_map))
  end

  @doc """
  Extract all counterparty/entity names from an SAP book summary.
  """
  @spec counterparty_names(map() | nil) :: [String.t()]
  def counterparty_names(nil), do: []
  def counterparty_names(%{positions: positions}) do
    positions
    |> Map.keys()
    |> Enum.reject(&is_nil/1)
  end
  def counterparty_names(_), do: []

  @doc """
  Extract vessel names from vessel tracking data.
  """
  @spec vessel_names(map() | nil) :: [String.t()]
  def vessel_names(nil), do: []
  def vessel_names(%{vessels: vessels}) when is_list(vessels) do
    vessels
    |> Enum.map(& &1[:name])
    |> Enum.reject(&is_nil/1)
  end
  def vessel_names(_), do: []

  # ── Private ──────────────────────────────────────────────

  # Determine whether the name looks like a vessel (starts with MV, MT, etc.)
  # or a counterparty entity, and assign an appropriate code prefix.
  defp next_code(name, idx) do
    prefix = cond do
      Regex.match?(~r/^(MV|MT|M\/V|M\/T|SS|MS|FSO|FPSO)\s/i, name) -> "VESSEL"
      Regex.match?(~r/^[A-Z]{2,4}-\d+/, name) -> "CONTRACT"   # SAP-style codes
      true -> "ENTITY"
    end
    "#{prefix}_#{String.pad_leading("#{idx}", 2, "0")}"
  end
end
