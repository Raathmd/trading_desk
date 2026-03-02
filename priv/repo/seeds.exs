# priv/repo/seeds.exs — Master seed entry point (dev / test environments)
#
# Usage:
#   mix run priv/repo/seeds.exs
#
# For production (Fly.io), use the release task instead:
#   fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Release.seed()'"
#
# Each seed is idempotent — safe to re-run. Run order matters (traders before contracts).

require Logger

Logger.info("Seeds: OperationalNodeSeed")
TradingDesk.Seeds.OperationalNodeSeed.run()

Logger.info("Seeds: TraderSeed")
TradingDesk.Seeds.TraderSeed.run()

Logger.info("Seeds: NH3ContractSeed")
TradingDesk.Seeds.NH3ContractSeed.run()

Logger.info("Seeds: tracked_vessels")
Code.eval_file("priv/repo/seeds/tracked_vessels.exs")

Logger.info("Seeds: users")
Code.eval_file("priv/repo/seeds/users.exs")

Logger.info("Seeds: variable_definitions")
Code.require_file("priv/repo/seeds/variable_definitions_seed.exs")
TradingDesk.Seeds.VariableDefinitionsSeed.run()

Logger.info("Seeds: api_configs")
Code.require_file("priv/repo/seeds/api_configs_seed.exs")
TradingDesk.Seeds.ApiConfigsSeed.run()

Logger.info("Seeds: product_group_frames")
Code.require_file("priv/repo/seeds/product_group_frames_seed.exs")
TradingDesk.Seeds.ProductGroupFramesSeed.run()

Logger.info("Seeds: all complete")
