package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Config for the gateway
type Config struct {
	Port         string
	RegistryURL  string
	Timeout      time.Duration
}

// BecknContext represents the context part of a Beckn message
type BecknContext struct {
	Domain        string `json:"domain"`
	Country       string `json:"country"`
	City          string `json:"city"`
	Action        string `json:"action"`
	CoreVersion   string `json:"core_version"`
	Version       string `json:"version"`
	BAPID         string `json:"bap_id"`
	BAPURI        string `json:"bap_uri"`
	BPPID         string `json:"bpp_id,omitempty"`
	BPPURI        string `json:"bpp_uri,omitempty"`
	TransactionID string `json:"transaction_id"`
	MessageID     string `json:"message_id"`
	Timestamp     string `json:"timestamp"`
	TTL           string `json:"ttl"`
}

// BecknRequest represents a Beckn protocol request
type BecknRequest struct {
	Context BecknContext           `json:"context"`
	Message map[string]interface{} `json:"message"`
}

// RegistryEntry represents a participant in the registry
type RegistryEntry struct {
	SubscriberID     string `json:"subscriber_id"`
	SubscriberURL    string `json:"subscriber_url"`
	Type             string `json:"type"`
	Domain           string `json:"domain"`
	City             string `json:"city"`
	Country          string `json:"country"`
	SigningPublicKey string `json:"signing_public_key"`
	EncrPublicKey    string `json:"encr_public_key"`
	Status           string `json:"status"`
	ValidFrom        string `json:"valid_from"`
	ValidUntil       string `json:"valid_until"`
	UniqueKeyID      string `json:"unique_key_id"`
}

// Gateway handles routing of Beckn requests
type Gateway struct {
	config      Config
	httpClient  *http.Client
	registryURL string
}

// NewGateway creates a new gateway instance
func NewGateway(config Config) *Gateway {
	return &Gateway{
		config: config,
		httpClient: &http.Client{
			Timeout: config.Timeout,
		},
		registryURL: config.RegistryURL,
	}
}

// lookupBPPs queries the registry for BPPs matching the domain and city
func (g *Gateway) lookupBPPs(ctx context.Context, domain, city, country string) ([]RegistryEntry, error) {
	// Query registry for BPPs
	url := fmt.Sprintf("%s/lookup", g.registryURL)
	
	query := map[string]interface{}{
		"type":    "BPP",
		"domain":  domain,
		"city":    city,
		"country": country,
	}
	
	queryJSON, err := json.Marshal(query)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal query: %w", err)
	}
	
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(queryJSON))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	
	resp, err := g.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to query registry: %w", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("registry returned status %d: %s", resp.StatusCode, string(body))
	}
	
	var entries []RegistryEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		return nil, fmt.Errorf("failed to decode registry response: %w", err)
	}
	
	// Filter for active BPPs
	var activeBPPs []RegistryEntry
	for _, entry := range entries {
		if entry.Status == "SUBSCRIBED" && entry.Type == "BPP" {
			activeBPPs = append(activeBPPs, entry)
		}
	}
	
	return activeBPPs, nil
}

// forwardToBPP forwards a request to a specific BPP
func (g *Gateway) forwardToBPP(ctx context.Context, bpp RegistryEntry, request *BecknRequest, authHeader string) (*http.Response, error) {
	// Update context with BPP information
	request.Context.BPPID = bpp.SubscriberID
	request.Context.BPPURI = bpp.SubscriberURL
	
	// Construct BPP endpoint URL
	action := request.Context.Action
	bppURL := fmt.Sprintf("%s/%s", strings.TrimSuffix(bpp.SubscriberURL, "/"), action)
	
	// Marshal request
	requestBody, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}
	
	// Create HTTP request
	req, err := http.NewRequestWithContext(ctx, "POST", bppURL, bytes.NewReader(requestBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	
	// Set headers
	req.Header.Set("Content-Type", "application/json")
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	
	// Forward request
	resp, err := g.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to forward request to BPP: %w", err)
	}
	
	return resp, nil
}

// handleSearch handles search requests by broadcasting to all relevant BPPs
func (g *Gateway) handleSearch(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	
	// Parse request body
	var request BecknRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, fmt.Sprintf("Invalid request body: %v", err), http.StatusBadRequest)
		return
	}
	
	// Get Authorization header to forward
	authHeader := r.Header.Get("Authorization")
	
	log.Printf("Gateway: Received search request for domain=%s, city=%s", 
		request.Context.Domain, request.Context.City)
	
	// Lookup BPPs from registry
	bpps, err := g.lookupBPPs(ctx, request.Context.Domain, request.Context.City, request.Context.Country)
	if err != nil {
		log.Printf("Failed to lookup BPPs: %v", err)
		// For testing, use hardcoded BPP if registry lookup fails
		bpps = []RegistryEntry{
			{
				SubscriberID:  "bpp-network",
				SubscriberURL: "http://localhost:6002",
				Type:          "BPP",
				Status:        "SUBSCRIBED",
			},
		}
	}
	
	log.Printf("Found %d BPPs for domain %s", len(bpps), request.Context.Domain)
	
	if len(bpps) == 0 {
		// Return NACK if no BPPs found
		response := map[string]interface{}{
			"message": map[string]interface{}{
				"ack": map[string]interface{}{
					"status": "NACK",
				},
			},
			"error": map[string]interface{}{
				"code":    "DOMAIN_ERROR",
				"message": fmt.Sprintf("No BPPs found for domain %s in city %s", request.Context.Domain, request.Context.City),
			},
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
		return
	}
	
	// Broadcast to all BPPs in parallel
	var wg sync.WaitGroup
	responses := make(chan map[string]interface{}, len(bpps))
	
	for _, bpp := range bpps {
		wg.Add(1)
		go func(bpp RegistryEntry) {
			defer wg.Done()
			
			// Clone request for this BPP
			bppRequest := request
			
			// Forward to BPP
			resp, err := g.forwardToBPP(ctx, bpp, &bppRequest, authHeader)
			if err != nil {
				log.Printf("Failed to forward to BPP %s: %v", bpp.SubscriberID, err)
				return
			}
			defer resp.Body.Close()
			
			// Read response
			var bppResponse map[string]interface{}
			if err := json.NewDecoder(resp.Body).Decode(&bppResponse); err != nil {
				log.Printf("Failed to decode BPP response from %s: %v", bpp.SubscriberID, err)
				return
			}
			
			responses <- bppResponse
		}(bpp)
	}
	
	// Wait for all responses
	wg.Wait()
	close(responses)
	
	// Collect all responses
	var allResponses []map[string]interface{}
	for resp := range responses {
		allResponses = append(allResponses, resp)
	}
	
	// Return ACK with async message
	// In a real implementation, responses would come back via on_search callbacks
	response := map[string]interface{}{
		"message": map[string]interface{}{
			"ack": map[string]interface{}{
				"status": "ACK",
			},
		},
	}
	
	if len(allResponses) == 0 {
		response["message"].(map[string]interface{})["ack"].(map[string]interface{})["status"] = "NACK"
		response["error"] = map[string]interface{}{
			"code":    "GATEWAY_ERROR",
			"message": "No responses received from BPPs",
		}
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// handleSelect handles select requests by routing to specific BPP
func (g *Gateway) handleSelect(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	
	// Parse request body
	var request BecknRequest
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, fmt.Sprintf("Invalid request body: %v", err), http.StatusBadRequest)
		return
	}
	
	// Get Authorization header to forward
	authHeader := r.Header.Get("Authorization")
	
	// For select, init, confirm etc., route to specific BPP mentioned in context
	if request.Context.BPPID == "" || request.Context.BPPURI == "" {
		http.Error(w, "BPP ID and URI required for select", http.StatusBadRequest)
		return
	}
	
	bpp := RegistryEntry{
		SubscriberID:  request.Context.BPPID,
		SubscriberURL: request.Context.BPPURI,
	}
	
	// Forward to specific BPP
	resp, err := g.forwardToBPP(ctx, bpp, &request, authHeader)
	if err != nil {
		log.Printf("Failed to forward to BPP: %v", err)
		http.Error(w, fmt.Sprintf("Failed to forward request: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	
	// Copy response back to client
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func main() {
	config := Config{
		Port:        getEnv("GATEWAY_PORT", "4500"),
		RegistryURL: getEnv("REGISTRY_URL", "http://localhost:3030"),
		Timeout:     30 * time.Second,
	}
	
	gateway := NewGateway(config)
	
	// Setup routes
	http.HandleFunc("/search", gateway.handleSearch)
	http.HandleFunc("/select", gateway.handleSelect)
	http.HandleFunc("/init", gateway.handleSelect)    // Uses same logic
	http.HandleFunc("/confirm", gateway.handleSelect) // Uses same logic
	http.HandleFunc("/status", gateway.handleSelect)  // Uses same logic
	http.HandleFunc("/track", gateway.handleSelect)   // Uses same logic
	http.HandleFunc("/cancel", gateway.handleSelect)  // Uses same logic
	http.HandleFunc("/update", gateway.handleSelect)  // Uses same logic
	http.HandleFunc("/rating", gateway.handleSelect)  // Uses same logic
	http.HandleFunc("/support", gateway.handleSelect) // Uses same logic
	
	// Health check
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})
	
	log.Printf("Gateway starting on port %s with registry at %s", config.Port, config.RegistryURL)
	if err := http.ListenAndServe(":"+config.Port, nil); err != nil {
		log.Fatalf("Failed to start gateway: %v", err)
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}