#!/bin/bash
# Shared logging/color utilities for heracles deployment scripts.
# Source from other scripts: source scripts/lib/logging.sh

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo -e "${BLUE}[INFO]${NC} $(_timestamp) - $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(_timestamp) - $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(_timestamp) - $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(_timestamp) - $*"; }
log_step()    { echo -e "${PURPLE}[STEP]${NC} $(_timestamp) - $*"; }
log_deploy()  { echo -e "${CYAN}[DEPLOY]${NC} $(_timestamp) - $*"; }

# Guard against double sourcing redefining functions.
export HERACLES_LOGGING_LOADED=1
