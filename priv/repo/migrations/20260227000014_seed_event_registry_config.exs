defmodule TradingDesk.Repo.Migrations.SeedEventRegistryConfig do
  use Ecto.Migration

  def up do
    # Trading desk events
    execute """
    INSERT INTO event_registry_config (id, event_type, source_process, should_vectorize, content_template, description, inserted_at, updated_at)
    VALUES
    (gen_random_uuid(), 'trading_desk_pre_solve', 'trading_desk', true,
     '{"sections": [{"label": "CONTEXT", "fields": ["commodity", "quantity", "delivery_window", "port_pair"]}, {"label": "MARKET STATE", "fields": ["market_snapshot"]}, {"label": "TRADER INTENT", "fields": ["trader_rationale"]}]}',
     'Trader initiates optimization — captures market state and intent',
     NOW(), NOW()),

    (gen_random_uuid(), 'trading_desk_post_solve', 'trading_desk', true,
     '{"sections": [{"label": "OPTIMIZER RESULT", "fields": ["recommendation"]}, {"label": "EXPLANATION", "fields": ["claude_explanation"]}]}',
     'HiGHS returns recommendation — captures solver output and Claude explanation',
     NOW(), NOW()),

    (gen_random_uuid(), 'trading_desk_decision_committed', 'trading_desk', true,
     '{"sections": [{"label": "DECISION", "fields": ["decision_type", "deal_reference"]}, {"label": "FULL ENVIRONMENT", "fields": ["market_snapshot"]}, {"label": "OPTIMIZER PRE", "fields": ["optimizer_pre_recommendation", "optimizer_pre_confidence", "claude_pre_explanation"]}, {"label": "OPTIMIZER POST", "fields": ["optimizer_post_recommendation", "claude_post_explanation"]}, {"label": "HISTORICAL CONTEXT", "fields": ["similar_historical_deals"]}, {"label": "TRADER DECISION", "fields": ["trader_decision"]}, {"label": "RATIONALE", "fields": ["trader_rationale", "deviation_from_optimizer"]}]}',
     'Trader commits to decision ledger — captures COMPLETE decision context with all environment variables',
     NOW(), NOW()),

    (gen_random_uuid(), 'trading_desk_execution_complete', 'trading_desk', true,
     '{"sections": [{"label": "DEAL", "fields": ["deal_reference", "commodity", "counterparty"]}, {"label": "FORECAST", "fields": ["forecast_margin", "forecast_delay"]}, {"label": "ACTUAL", "fields": ["actual_margin", "actual_delay", "actual_demurrage", "operational_issues"]}, {"label": "VARIANCE", "fields": ["forecast_vs_actual"]}]}',
     'Deal execution completes — captures actual outcomes for forecast comparison',
     NOW(), NOW())
    ON CONFLICT (event_type, source_process) DO NOTHING
    """

    # Contract management events
    execute """
    INSERT INTO event_registry_config (id, event_type, source_process, should_vectorize, content_template, description, inserted_at, updated_at)
    VALUES
    (gen_random_uuid(), 'cm_step_completed', 'contract_management', false,
     '{"sections": [{"label": "STEP", "fields": ["step_number", "step_name", "step_data"]}]}',
     'Individual wizard step completed — low priority, do not vectorize by default',
     NOW(), NOW()),

    (gen_random_uuid(), 'cm_optimizer_validated', 'contract_management', true,
     '{"sections": [{"label": "CONTRACT CONTEXT", "fields": ["contract_context"]}, {"label": "MARKET STATE", "fields": ["market_snapshot"]}, {"label": "SIMILAR DEALS", "fields": ["similar_deals"]}, {"label": "OPTIMIZER", "fields": ["optimizer_result", "post_solve_explanation"]}, {"label": "PRE-SOLVE FRAMING", "fields": ["pre_solve_framing"]}]}',
     'Optimizer validates proposed contract terms — captures full validation context',
     NOW(), NOW()),

    (gen_random_uuid(), 'cm_contract_created', 'contract_management', true,
     '{"sections": [{"label": "CONTRACT", "fields": ["contract_id", "counterparty", "commodity"]}, {"label": "TERMS", "fields": ["terms", "selected_clauses"]}, {"label": "OPTIMIZER VALIDATION", "fields": ["optimizer_result", "claude_explanation"]}, {"label": "MARKET STATE", "fields": ["market_snapshot"]}]}',
     'Contract finalized — captures complete contract with all terms and context',
     NOW(), NOW()),

    (gen_random_uuid(), 'cm_contract_approved', 'contract_management', true,
     '{"sections": [{"label": "CONTRACT", "fields": ["contract_id"]}, {"label": "APPROVAL", "fields": ["approver_id", "conditions", "final_terms"]}]}',
     'Contract approved — captures approval chain and any conditions',
     NOW(), NOW()),

    (gen_random_uuid(), 'cm_contract_version_created', 'contract_management', true,
     '{"sections": [{"label": "CONTRACT", "fields": ["contract_id", "version_number"]}, {"label": "CHANGES", "fields": ["changes_from_previous", "change_summary"]}, {"label": "MARKET STATE", "fields": ["market_snapshot"]}]}',
     'New contract version created — captures what changed and why',
     NOW(), NOW())
    ON CONFLICT (event_type, source_process) DO NOTHING
    """

    # Backfill events
    execute """
    INSERT INTO event_registry_config (id, event_type, source_process, should_vectorize, content_template, description, inserted_at, updated_at)
    VALUES
    (gen_random_uuid(), 'historical_contract_ingestion', 'sap_backfill', true,
     '{"sections": [{"label": "HISTORICAL CONTRACT", "fields": ["sap_contract_data"]}, {"label": "LLM FRAMING", "fields": ["llm_framing_output"]}]}',
     'SAP historical contract ingested and framed by LLM — vectorization handled inline by backfill worker',
     NOW(), NOW())
    ON CONFLICT (event_type, source_process) DO NOTHING
    """
  end

  def down do
    execute "DELETE FROM event_registry_config WHERE source_process IN ('trading_desk', 'contract_management', 'sap_backfill')"
  end
end
