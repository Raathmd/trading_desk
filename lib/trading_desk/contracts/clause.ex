defmodule TradingDesk.Contracts.Clause do
  @moduledoc """
  A single extracted clause from a physical contract.

  The struct stores identity and content fields. Everything the LLM
  extracts — including solver-relevant mappings — lives in `extracted_fields`.
  This keeps the storage layer decoupled from the solver frame.

  ## Identity fields
    - `clause_id` — descriptive ID from the LLM (e.g., "PRICE", "FORCE_MAJEURE")
    - `type` — broad category for UI grouping
    - `category` — finer-grained category from the LLM

  ## Content fields
    - `description` — original clause text from the contract (source_text)
    - `reference_section` — section/paragraph reference in original document
    - `confidence` — LLM's extraction confidence

  ## extracted_fields (flexible map — everything the LLM found)
  The LLM returns all extracted data here. Common keys include:
    - "parameter"       — solver variable key (e.g., "nola_buy") or null
    - "operator"        — "==" | ">=" | "<=" | "between" | null
    - "value"           — numeric bound
    - "value_upper"     — upper bound for "between" ranges
    - "unit"            — "$/ton", "tons", "days", etc.
    - "penalty_per_unit" — $/ton or $/day penalty rate
    - "penalty_cap"     — maximum penalty exposure
    - "period"          — "monthly", "quarterly", "annual", "spot"
    - Plus any clause-specific fields the LLM discovers

  The ConstraintBridge reads solver-relevant keys from extracted_fields
  at solve time. No rigid assumptions about which fields exist.
  """

  @enforce_keys [:type, :description]

  defstruct [
    :id,
    :clause_id,          # descriptive ID from LLM: "PRICE", "QUANTITY_TOLERANCE", etc.
    :type,               # :obligation | :penalty | :condition | :price_term | :limit |
                         # :delivery | :metadata | :legal | :compliance | :operational
    :category,           # from LLM: :core_terms | :commercial | :logistics | etc.
    :description,        # original clause text from the contract
    :reference_section,  # section/paragraph reference in original document
    :confidence,         # :high | :medium | :low — LLM extraction confidence
    :extracted_fields,   # map — all LLM-extracted data including solver mappings
    extracted_at: nil
  ]

  @type clause_type :: :obligation | :penalty | :condition | :price_term | :limit |
                       :delivery | :metadata | :legal | :compliance | :operational

  @type confidence :: :high | :medium | :low

  @type t :: %__MODULE__{
    id: String.t() | nil,
    clause_id: String.t() | nil,
    type: clause_type(),
    category: atom() | nil,
    description: String.t(),
    reference_section: String.t() | nil,
    confidence: confidence() | nil,
    extracted_fields: map() | nil,
    extracted_at: DateTime.t() | nil
  }

  # ── Accessor helpers for solver-relevant fields ──
  # These read from extracted_fields at solve time, returning nil
  # if the field isn't present. Keeps ConstraintBridge clean.

  @doc "Get the solver parameter key (atom) from extracted_fields"
  def parameter(%__MODULE__{extracted_fields: ef}) when is_map(ef) do
    case ef["parameter"] do
      nil -> nil
      s when is_binary(s) -> String.to_atom(s)
      a when is_atom(a) -> a
    end
  end
  def parameter(_), do: nil

  @doc "Get the operator atom from extracted_fields"
  def operator(%__MODULE__{extracted_fields: ef}) when is_map(ef) do
    case ef["operator"] do
      "==" -> :==
      ">=" -> :>=
      "<=" -> :<=
      "between" -> :between
      a when is_atom(a) -> a
      _ -> nil
    end
  end
  def operator(_), do: nil

  @doc "Get the numeric value from extracted_fields"
  def value(%__MODULE__{extracted_fields: ef}) when is_map(ef) do
    case ef["value"] do
      v when is_number(v) -> v
      _ -> nil
    end
  end
  def value(_), do: nil

  @doc "Get the upper bound for :between ranges"
  def value_upper(%__MODULE__{extracted_fields: ef}) when is_map(ef) do
    case ef["value_upper"] do
      v when is_number(v) -> v
      _ -> nil
    end
  end
  def value_upper(_), do: nil

  @doc "Get the penalty rate from extracted_fields"
  def penalty_per_unit(%__MODULE__{extracted_fields: ef}) when is_map(ef) do
    case ef["penalty_per_unit"] do
      v when is_number(v) -> v
      _ -> nil
    end
  end
  def penalty_per_unit(_), do: nil

  @doc "Get any field from extracted_fields by string key"
  def field(%__MODULE__{extracted_fields: ef}, key) when is_map(ef) and is_binary(key) do
    Map.get(ef, key)
  end
  def field(_, _), do: nil

  @doc "Get the unit string from extracted_fields"
  def unit(%__MODULE__{extracted_fields: ef}) when is_map(ef), do: ef["unit"]
  def unit(_), do: nil

  @doc "Get the period from extracted_fields"
  def period(%__MODULE__{extracted_fields: ef}) when is_map(ef), do: ef["period"]
  def period(_), do: nil

  @doc "Generate a unique clause ID"
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
