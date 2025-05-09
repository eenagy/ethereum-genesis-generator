#!/bin/bash -e

# Default values
DEFAULT_DATA_DIR="/data"
DEFAULT_DEFAULTS_ENV="/defaults/defaults.env"
DEFAULT_VALUES_ENV="/config/values.env"
DEFAULT_CONFIG_DIR="/config"
DEFAULT_EL_GEN_PATH="/apps/el-gen/generate_genesis.sh"

# Set defaults AFTER parsing
DATA_DIR="${DEFAULT_DATA_DIR}"
DEFAULTS_ENV="${DEFAULT_DEFAULTS_ENV}"
VALUES_ENV="${DEFAULT_VALUES_ENV}"
CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
EL_GEN_PATH="${DEFAULT_EL_GEN_PATH}"

while [[ $# -gt 0 ]]; do
  case $1 in
  --data-dir)
    DATA_DIR="$2"
    shift 2
    ;;
  --defaults-env)
    DEFAULTS_ENV="$2"
    shift 2
    ;;
  --values-env)
    VALUES_ENV="$2"
    shift 2
    ;;
  --config-dir)
    CONFIG_DIR="$2"
    shift 2
    ;;
  --el-gen-path)
    EL_GEN_PATH="$2"
    shift 2
    ;;
  *)
    # Save the command (el, cl, all)
    if [[ -z "$COMMAND" ]]; then
      COMMAND="$1"
    fi
    shift
    ;;
  esac
done

echo "Using DATA_DIR: $DATA_DIR"
echo "Using DEFAULTS_ENV: $DEFAULTS_ENV"
echo "Using CONFIG_DIR: $CONFIG_DIR"
echo "Using EL_GEN_PATH: $EL_GEN_PATH"

if [ -f "$DEFAULTS_ENV" ]; then
  source "$DEFAULTS_ENV"
fi

if [ -f "$VALUES_ENV" ]; then
  source "$VALUES_ENV"
fi

SERVER_ENABLED="${SERVER_ENABLED:-false}"
SERVER_PORT="${SERVER_PORT:-8000}"

gen_shared_files() {
  set -x
  # Shared files
  mkdir -p "$DATA_DIR/metadata"
  if ! [ -f "$DATA_DIR/jwt/jwtsecret" ]; then
    mkdir -p "$DATA_DIR/jwt"
    echo -n 0x$(openssl rand -hex 32 | tr -d "\n") >"$DATA_DIR/jwt/jwtsecret"
  fi
  if [ -f "$DATA_DIR/metadata/genesis.json" ]; then
    terminalTotalDifficulty=$(cat "$DATA_DIR/metadata/genesis.json" | jq -r '.config.terminalTotalDifficulty | tostring')
    sed -i "s/TERMINAL_TOTAL_DIFFICULTY:.*/TERMINAL_TOTAL_DIFFICULTY: $terminalTotalDifficulty/" "$DATA_DIR/metadata/config.yaml"
  fi
}

gen_el_config() {
  set -x
  if ! [ -f "$DATA_DIR/metadata/genesis.json" ]; then
    mkdir -p "$DATA_DIR/metadata"
    source "$EL_GEN_PATH"
    generate_genesis "$DATA_DIR/metadata"
  else
    echo "el genesis already exists. skipping generation..."
  fi
}

gen_minimal_config() {
  declare -A replacements=(
    [MIN_PER_EPOCH_CHURN_LIMIT]=2
    [MIN_EPOCHS_FOR_BLOCK_REQUESTS]=272
    [WHISK_EPOCHS_PER_SHUFFLING_PHASE]=4
    [WHISK_PROPOSER_SELECTION_GAP]=1
    [MIN_PER_EPOCH_CHURN_LIMIT_ELECTRA]=64000000000
    [MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT]=128000000000
  )

  for key in "${!replacements[@]}"; do
    sed -i "s/$key:.*/$key: ${replacements[$key]}/" "$DATA_DIR/metadata/config.yaml"
  done
}

gen_cl_config() {
  set -x
  # Consensus layer: Check if genesis already exists
  if ! [ -f "$DATA_DIR/metadata/genesis.ssz" ]; then
    tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
    mkdir -p "$DATA_DIR/metadata"
    mkdir -p "$DATA_DIR/parsed"
    HUMAN_READABLE_TIMESTAMP=$(date -u -d @"$GENESIS_TIMESTAMP" +"%Y-%b-%d %I:%M:%S %p %Z")
    COMMENT="# $HUMAN_READABLE_TIMESTAMP"
    export MAX_REQUEST_BLOB_SIDECARS_ELECTRA=$(($MAX_REQUEST_BLOCKS_DENEB * $MAX_BLOBS_PER_BLOCK_ELECTRA))
    export MAX_REQUEST_BLOB_SIDECARS_FULU=$(($MAX_REQUEST_BLOCKS_DENEB * $MAX_BLOBS_PER_BLOCK_FULU))
    envsubst <"$CONFIG_DIR/cl/config.yaml" >"$DATA_DIR/metadata/config.yaml"
    sed -i "s/#HUMAN_TIME_PLACEHOLDER/$COMMENT/" "$DATA_DIR/metadata/config.yaml"
    envsubst <"$CONFIG_DIR/cl/mnemonics.yaml" >$tmp_dir/mnemonics.yaml
    # Conditionally override values if preset is "minimal"
    if [[ "$PRESET_BASE" == "minimal" ]]; then
      gen_minimal_config
    fi
    cp $tmp_dir/mnemonics.yaml "$DATA_DIR/metadata/mnemonics.yaml"
    # Create deposit_contract.txt and deposit_contract_block.txt
    grep DEPOSIT_CONTRACT_ADDRESS "$DATA_DIR/metadata/config.yaml" | cut -d " " -f2 >"$DATA_DIR/metadata/deposit_contract.txt"
    echo $CL_EXEC_BLOCK >"$DATA_DIR/metadata/deposit_contract_block.txt"
    echo $BEACON_STATIC_ENR >"$DATA_DIR/metadata/bootstrap_nodes.txt"
    # Envsubst mnemonics
    if [ "$WITHDRAWAL_TYPE" == "0x00" ]; then
      export WITHDRAWAL_ADDRESS="null"
    fi
    envsubst <"$CONFIG_DIR/cl/mnemonics.yaml" >"$tmp_dir/mnemonics.yaml"
    # Generate genesis
    genesis_args+=(
      devnet
      --config "$DATA_DIR/metadata/config.yaml"
      --eth1-config "$DATA_DIR/metadata/genesis.json"
      --mnemonics "$tmp_dir/mnemonics.yaml"
      --state-output "$DATA_DIR/metadata/genesis.ssz"
      --json-output "$DATA_DIR/parsed/parsedConsensusGenesis.json"
    )

    if [[ $SHADOW_FORK_FILE != "" ]]; then
      genesis_args+=(--shadow-fork-block=$SHADOW_FORK_FILE)
    elif [[ $SHADOW_FORK_RPC != "" ]]; then
      genesis_args+=(--shadow-fork-rpc=$SHADOW_FORK_RPC)
    fi

    if ! [ -z "$CL_ADDITIONAL_VALIDATORS" ]; then
      if [[ $CL_ADDITIONAL_VALIDATORS = /* ]]; then
        validators_file=$CL_ADDITIONAL_VALIDATORS
      else
        validators_file="$CONFIG_DIR/$CL_ADDITIONAL_VALIDATORS"
      fi
      genesis_args+=(--additional-validators $validators_file)
    fi

    eth-beacon-genesis "${genesis_args[@]}"
    echo "Genesis args: ${genesis_args[@]}"
    echo "Genesis block number: $(jq -r '.latest_execution_payload_header.block_number' "$DATA_DIR/parsed/parsedConsensusGenesis.json")"
    echo "Genesis block hash: $(jq -r '.latest_execution_payload_header.block_hash' "$DATA_DIR/parsed/parsedConsensusGenesis.json")"
    jq -r '.eth1_data.block_hash' "$DATA_DIR/parsed/parsedConsensusGenesis.json" | tr -d '\n' >"$DATA_DIR/metadata/deposit_contract_block_hash.txt"
    jq -r '.genesis_validators_root' "$DATA_DIR/parsed/parsedConsensusGenesis.json" | tr -d '\n' >"$DATA_DIR/metadata/genesis_validators_root.txt"
  else
    echo "cl genesis already exists. skipping generation..."
  fi
}

gen_all_config() {
  gen_el_config
  gen_cl_config
  gen_shared_files
}

case $COMMAND in
el)
  gen_el_config
  ;;
cl)
  gen_cl_config
  ;;
all)
  gen_all_config
  ;;
*)
  set +x
  echo "Usage: $(basename $0) [all|cl|el] [--data-dir=/path/to/data] [--config-dir=/path/to/config] [--defaults-env=/path/to/defaults.env] [--values-env=/path/to/values.env] [--el-gen-path=/path/to/generate_genesis.sh]"
  echo "Options:"
  echo "  --data-dir=PATH         Set custom data directory (default: $DEFAULT_DATA_DIR)"
  echo "  --config-dir=PATH       Set custom config directory (default: $DEFAULT_CONFIG_DIR)"
  echo "  --defaults-env=PATH     Set custom defaults env file (default: $DEFAULT_DEFAULTS_ENV)"
  echo "  --values-env=PATH       Set custom values env file (default: $DEFAULT_VALUES_ENV)"
  echo "  --el-gen-path=PATH      Set custom EL generator script path (default: $DEFAULT_EL_GEN_PATH)"
  exit 1
  ;;
esac

# Start webserver
if [ "$SERVER_ENABLED" = true ]; then
  cd /data && exec python3 -m http.server "$SERVER_PORT"
fi
