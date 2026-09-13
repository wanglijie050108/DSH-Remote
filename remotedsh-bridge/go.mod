module remotedsh-bridge

go 1.22

replace remotedsh-contract/go => ../remotedsh-contract/go

require (
	github.com/gorilla/websocket v1.5.3
	remotedsh-contract/go v0.0.0-00010101000000-000000000000
)
