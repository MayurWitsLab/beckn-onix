package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// BecknRequest represents incoming request
type BecknRequest struct {
	Context map[string]interface{} `json:"context"`
	Message map[string]interface{} `json:"message"`
}

// Mock BPP server that responds to Beckn protocol requests
func main() {
	port := "6002"
	
	// Handle search requests
	http.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
		var req BecknRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid request", http.StatusBadRequest)
			return
		}
		
		// Log the request
		auth := r.Header.Get("Authorization")
		log.Printf("Mock BPP: Received SEARCH request")
		log.Printf("  Transaction ID: %v", req.Context["transaction_id"])
		log.Printf("  Message ID: %v", req.Context["message_id"])
		log.Printf("  Authorization: %s...", auth[:50])
		
		// Send ACK response (in real scenario, on_search would be sent async)
		response := map[string]interface{}{
			"message": map[string]interface{}{
				"ack": map[string]interface{}{
					"status": "ACK",
				},
			},
		}
		
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
		
		// Simulate async on_search callback
		go func() {
			time.Sleep(1 * time.Second)
			log.Printf("Mock BPP: Would send on_search callback to BAP at %v", req.Context["bap_uri"])
		}()
	})
	
	// Handle select requests
	http.HandleFunc("/select", func(w http.ResponseWriter, r *http.Request) {
		var req BecknRequest
		json.NewDecoder(r.Body).Decode(&req)
		
		log.Printf("Mock BPP: Received SELECT request for transaction %v", req.Context["transaction_id"])
		
		response := map[string]interface{}{
			"message": map[string]interface{}{
				"ack": map[string]interface{}{
					"status": "ACK",
				},
			},
		}
		
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	})
	
	// Handle other endpoints
	endpoints := []string{"/init", "/confirm", "/status", "/track", "/cancel", "/update", "/rating", "/support"}
	for _, endpoint := range endpoints {
		ep := endpoint // Capture for closure
		http.HandleFunc(ep, func(w http.ResponseWriter, r *http.Request) {
			var req BecknRequest
			json.NewDecoder(r.Body).Decode(&req)
			
			log.Printf("Mock BPP: Received %s request for transaction %v", ep, req.Context["transaction_id"])
			
			response := map[string]interface{}{
				"message": map[string]interface{}{
					"ack": map[string]interface{}{
						"status": "ACK",
					},
				},
			}
			
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(response)
		})
	}
	
	// Health check
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Mock BPP is healthy"))
	})
	
	log.Printf("Mock BPP starting on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatalf("Failed to start mock BPP: %v", err)
	}
}