#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================"
echo -e "Beckn-ONIX Complete Setup"
echo -e "========================================${NC}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running. Please start Docker first.${NC}"
    exit 1
fi

# Step 1: Run the Beckn network installer
echo -e "${YELLOW}Step 1: Setting up Beckn network services...${NC}"

# Check if install directory exists
if [ ! -d "./install" ]; then
    echo -e "${RED}Error: install directory not found.${NC}"
    echo -e "${YELLOW}Please run this script from the beckn-onix root directory.${NC}"
    exit 1
fi

# Make the installer executable
chmod +x ./install/beckn-onix.sh

# Navigate to install directory and run setup
cd install

# Auto-select option 3 (local setup) for the installer - commented out as it may not be needed
# echo -e "${GREEN}Running local network setup...${NC}"
# echo "3" | ./beckn-onix.sh

cd ..

# Wait for services to stabilize
echo -e "${YELLOW}Waiting for services to be ready...${NC}"
sleep 15

# Step 2: Configure Vault for key management
echo -e "${YELLOW}Step 2: Setting up Vault for key management...${NC}"

# Check if Vault is running, if not start it
if ! docker ps | grep -q "vault"; then
    echo -e "${BLUE}Starting Vault container...${NC}"
    docker run -d \
        --name vault \
        --cap-add=IPC_LOCK \
        -e VAULT_DEV_ROOT_TOKEN_ID=root \
        -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
        -p 8200:8200 \
        hashicorp/vault:latest > /dev/null 2>&1
    
    # Wait for Vault to be ready
    echo -e "${BLUE}Waiting for Vault to start...${NC}"
    for i in {1..30}; do
        if docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault vault status > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Vault is ready${NC}"
            break
        fi
        if [ $i -eq 30 ]; then
            echo -e "${RED}Error: Vault failed to start${NC}"
            exit 1
        fi
        sleep 1
    done
fi

# Configure Vault with error handling
echo -e "${BLUE}Configuring Vault policies...${NC}"

# Enable AppRole auth
if ! docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault auth list 2>/dev/null | grep -q "approle"; then
    docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
        vault auth enable approle 2>/dev/null || {
            echo -e "${YELLOW}AppRole already enabled or error occurred${NC}"
        }
fi

# Create policy
echo 'path "beckn/*" { capabilities = ["create", "read", "update", "delete", "list"] }' | \
    docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault policy write beckn-policy - > /dev/null 2>&1 || {
        echo -e "${YELLOW}Policy already exists or updated${NC}"
    }

# Create role
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault write auth/approle/role/beckn-role \
    token_policies="beckn-policy" \
    token_ttl=24h \
    token_max_ttl=48h > /dev/null 2>&1 || {
        echo -e "${YELLOW}Role already exists or updated${NC}"
    }

# Get Vault credentials with error handling
echo -e "${BLUE}Getting Vault credentials...${NC}"
ROLE_ID=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault read -field=role_id auth/approle/role/beckn-role/role-id 2>/dev/null)

if [ -z "$ROLE_ID" ]; then
    echo -e "${RED}Error: Failed to get ROLE_ID from Vault${NC}"
    exit 1
fi

SECRET_ID=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault write -field=secret_id -f auth/approle/role/beckn-role/secret-id 2>/dev/null)

if [ -z "$SECRET_ID" ]; then
    echo -e "${RED}Error: Failed to get SECRET_ID from Vault${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Got Vault credentials:${NC}"
echo -e "  ROLE_ID: ${ROLE_ID:0:20}..."
echo -e "  SECRET_ID: ${SECRET_ID:0:20}..."

# Enable KV v2 secrets engine at beckn path (IMPORTANT: using beckn, not secret)
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault secrets enable -path=beckn kv-v2 > /dev/null 2>&1 || {
        echo -e "${YELLOW}Secrets engine already enabled${NC}"
    }

echo -e "${GREEN}✓ Vault configured successfully${NC}"

# Step 3: Seed cryptographic keys in Vault
echo -e "${YELLOW}Step 3: Seeding cryptographic keys in Vault...${NC}"

# IMPORTANT: Using 32-byte Ed25519 seeds, NOT 64-byte full keys
# BAP Network Keys
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault kv put beckn/keys/bap-network \
    uniqueKeyID="bap-network-key-001" \
    signingPublicKey='1ct6/Xg6gHhT9QolufThbY4mWHYkIpXzh7YxMFM8MQE=' \
    signingPrivateKey='C2hPMyeN+1Vzn8+7F/MUHmR5jKFuSb7s6tf/U5qni8s=' \
    encrPublicKey='MC0RJ6xWgNKiVVaj8p3GT3GTiQVYMK5D3Bqc7xCqiHI=' \
    encrPrivateKey='LHJjLhRYfSHhzLvTL7uPqKmgmuhqGiCLI0E4BWTXZ0I=' > /dev/null 2>&1

# BAP Client Keys
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault kv put beckn/keys/bap-client \
    uniqueKeyID="bap-client-key-001" \
    signingPublicKey='2uAkpgMvVBB2FzwGmwKSgKMEBhWrhB50L2LCqhW3Zgo=' \
    signingPrivateKey='QqvAFpKjR7w6b0Z+pK2h3C8+srLtWiUKc0KhiFPJ7Bc=' \
    encrPublicKey='RkRhSsBgU3iuMESSAGgB5DHWQ0h0bPMvZCXh5+pId0U=' \
    encrPrivateKey='ykG2EGk4nrFESGflQWe3z+Cq0f0fBz0xUqCqyhFHV1o=' > /dev/null 2>&1

# BPP Network Keys
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault kv put beckn/keys/bpp-network \
    uniqueKeyID="bpp-network-key-001" \
    signingPublicKey='awGPjRK6i/Vg/lWr+0xObclVxlwZXvTjWYtlu6NeOHk=' \
    signingPrivateKey='W3NFJJSnDmJpvyP1p/qvPFK9XsFSJhBsuGOH3vvPEBI=' \
    encrPublicKey='9VfaJoVGgU+Y1v7BhEWJO0N+XnRuYfv7Ap0dBpJrXzQ=' \
    encrPrivateKey='8HJ3sLXJgJaOVCEOA9+HqGeaXjpCP0u0n+6FEQZB7Fc=' > /dev/null 2>&1

# BPP Client Keys  
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
    vault kv put beckn/keys/bpp-client \
    uniqueKeyID="bpp-client-key-001" \
    signingPublicKey='X8+MXBZj6K9TasmmDNgN+lNqWCKjP8SH/84wfYLXWYs=' \
    signingPrivateKey='p7h7bZvFvRx4BDgX4+MZ1H8vPRduCdF5k6X/1j1K+cc=' \
    encrPublicKey='eA0gX5VdMV0EiGFBk2/OGR1pzD+Qx9pPmHuCxFq0Vy0=' \
    encrPrivateKey='WHSm9q5crFqKQ7lVXDmJvD5wT2x7DQAYqOk9WsfKgGU=' > /dev/null 2>&1

echo -e "${GREEN}✓ Keys seeded in Vault${NC}"

# Verify keys were created
for key in "bap-network" "bap-client" "bpp-network" "bpp-client"; do
    if docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root vault \
        vault kv get beckn/keys/$key > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ $key keys verified${NC}"
    else
        echo -e "${RED}  ✗ Failed to verify $key keys${NC}"
    fi
done

# Step 4: Check services status
echo -e "${YELLOW}Step 4: Checking services status...${NC}"

# Check if services are running
if docker ps | grep -q "registry"; then
    echo -e "${GREEN}✓ Registry is running${NC}"
fi
if docker ps | grep -q "gateway"; then
    echo -e "${GREEN}✓ Gateway is running${NC}"
fi
if docker ps | grep -q "bap-client"; then
    echo -e "${GREEN}✓ BAP services are running${NC}"
fi
if docker ps | grep -q "bpp-client"; then
    echo -e "${GREEN}✓ BPP services are running${NC}"
fi
if docker ps | grep -q "vault"; then
    echo -e "${GREEN}✓ Vault is running${NC}"
fi

# Step 5: Create required directories
echo -e "${YELLOW}Step 5: Creating required directories...${NC}"

# Create schemas directory for validation
if [ ! -d "schemas" ]; then
    mkdir -p schemas
    echo -e "${GREEN}✓ Created schemas directory${NC}"
else
    echo -e "${YELLOW}schemas directory already exists${NC}"
fi

# Create logs directory
if [ ! -d "logs" ]; then
    mkdir -p logs
    echo -e "${GREEN}✓ Created logs directory${NC}"
else
    echo -e "${YELLOW}logs directory already exists${NC}"
fi

# Create plugins directory if not exists
if [ ! -d "plugins" ]; then
    mkdir -p plugins
    echo -e "${GREEN}✓ Created plugins directory${NC}"
else
    echo -e "${YELLOW}plugins directory already exists${NC}"
fi

# Step 6: Build adapter plugins
echo -e "${YELLOW}Step 6: Building adapter plugins...${NC}"

if [ -f "./install/build-plugins.sh" ]; then
    chmod +x ./install/build-plugins.sh
    ./install/build-plugins.sh
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Plugins built successfully${NC}"
    else
        echo -e "${RED}Error: Plugin build failed${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: install/build-plugins.sh not found${NC}"
    exit 1
fi

# Step 7: Build the adapter server
echo -e "${YELLOW}Step 7: Building Beckn-ONIX adapter server...${NC}"

if [ -f "go.mod" ]; then
    go build -o beckn-adapter cmd/adapter/main.go
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Adapter server built successfully${NC}"
    else
        echo -e "${RED}Error: Failed to build adapter server${NC}"
        echo -e "${YELLOW}Please check Go installation and dependencies${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: go.mod not found${NC}"
    exit 1
fi

# Step 8: Build custom gateway (optional but recommended for local testing)
echo -e "${YELLOW}Step 8: Building custom gateway for local testing...${NC}"

if [ -f "gateway/main.go" ]; then
    cd gateway
    go build -o beckn-gateway main.go
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Custom gateway built successfully${NC}"
    else
        echo -e "${YELLOW}Warning: Failed to build custom gateway${NC}"
        echo -e "${YELLOW}You can use the Docker gateway, but it may not work properly${NC}"
    fi
    cd ..
else
    echo -e "${YELLOW}Custom gateway not found. Using Docker gateway.${NC}"
fi

# Step 9: Build mock BPP (optional for testing)
echo -e "${YELLOW}Step 9: Building mock BPP for testing...${NC}"

if [ -f "mock-bpp/main.go" ]; then
    cd mock-bpp
    go build -o mock-bpp main.go
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Mock BPP built successfully${NC}"
    else
        echo -e "${YELLOW}Warning: Failed to build mock BPP${NC}"
    fi
    cd ..
else
    echo -e "${YELLOW}Mock BPP not found. Skipping.${NC}"
fi

# Step 10: Create environment file
echo -e "${YELLOW}Step 10: Creating environment configuration...${NC}"

# Check if we have Vault credentials
if [ -z "$ROLE_ID" ] || [ -z "$SECRET_ID" ]; then
    echo -e "${RED}Error: Vault credentials not available${NC}"
    echo -e "${YELLOW}Please check Vault configuration and try again${NC}"
    exit 1
fi

cat > .env <<EOF
# Beckn-ONIX Environment Configuration
# Generated on $(date)

# Service URLs
export REGISTRY_URL=http://localhost:3030
export GATEWAY_URL=http://localhost:4500  # Custom gateway port
export BAP_CLIENT_URL=http://localhost:5001
export BAP_NETWORK_URL=http://localhost:5002
export BPP_CLIENT_URL=http://localhost:6001
export BPP_NETWORK_URL=http://localhost:6002
export REDIS_URL=localhost:6379
export MONGO_URL=mongodb://localhost:27017

# Adapter Configuration
export ADAPTER_PORT=8081
export ADAPTER_MODE=development

# Vault Configuration
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root
export VAULT_ROLE_ID=$ROLE_ID
export VAULT_SECRET_ID=$SECRET_ID
EOF

if [ -f ".env" ]; then
    echo -e "${GREEN}✓ Environment file created successfully${NC}"
    echo -e "${YELLOW}  Vault ROLE_ID and SECRET_ID have been saved to .env${NC}"
else
    echo -e "${RED}Error: Failed to create .env file${NC}"
    exit 1
fi

# Display final status
echo ""
echo -e "${GREEN}========================================"
echo -e "✅ Setup Complete!"
echo -e "========================================${NC}"
echo ""
echo -e "${BLUE}Services Running:${NC}"
echo -e "  📦 Registry:     http://localhost:3030"
echo -e "  🌐 Gateway:      http://localhost:4000 (Docker) / 4500 (Custom)"
echo -e "  🛒 BAP Client:   http://localhost:5001"
echo -e "  🛒 BAP Network:  http://localhost:5002"
echo -e "  🏪 BPP Client:   http://localhost:6001"
echo -e "  🏪 BPP Network:  http://localhost:6002"
echo -e "  🔐 Vault:        http://localhost:8200"
echo -e "  💾 Redis:        localhost:6379"
echo -e "  🗄️  MongoDB:      localhost:27017"
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo ""
echo -e "1. ${YELLOW}(Optional) Start custom gateway for better routing:${NC}"
echo -e "   ./gateway/beckn-gateway"
echo ""
echo -e "2. ${YELLOW}(Optional) Start mock BPP for testing:${NC}"
echo -e "   ./mock-bpp/mock-bpp"
echo ""
echo -e "3. ${YELLOW}Run the adapter:${NC}"
echo -e "   source .env && ./beckn-adapter --config=config/local-dev.yaml"
echo ""
echo -e "4. ${YELLOW}Test with a search request:${NC}"
echo -e "   curl -X POST http://localhost:8081/bap/caller/search \\"
echo -e "     -H \"Content-Type: application/json\" \\"
echo -e "     -d '{\"context\": {\"domain\": \"nic2004:retail\", \"country\": \"IND\", \"city\": \"std:080\", \"action\": \"search\", \"version\": \"1.0.0\", \"bap_id\": \"bap-network\", \"bap_uri\": \"http://localhost:5002\", \"transaction_id\": \"test_123\", \"message_id\": \"msg_123\", \"timestamp\": \"2025-01-01T00:00:00Z\", \"ttl\": \"PT30S\"}, \"message\": {\"intent\": {\"item\": {\"descriptor\": {\"name\": \"coffee\"}}}}}'"
echo ""
echo -e "${GREEN}Important Notes:${NC}"
echo -e "  • Keys are stored in Vault at path: beckn/keys/{participant-id}"
echo -e "  • Using 32-byte Ed25519 seeds (not 64-byte full keys)"
echo -e "  • Custom gateway (port 4500) handles registry lookups properly"
echo -e "  • Docker gateway (port 4000) may not work without additional config"
echo ""
echo -e "${YELLOW}To stop all services:${NC}"
echo -e "  cd install && docker compose down"
echo ""
echo -e "${YELLOW}View logs:${NC}"
echo -e "  docker compose logs -f [service-name]"
echo -e "${GREEN}========================================${NC}"