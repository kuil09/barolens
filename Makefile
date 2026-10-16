.DEFAULT_GOAL := check
.PHONY: check test build package clean

# Example: make test ARGS='--derived-data "/private/tmp/barolens-derived-data.ABC123"'
check test build package clean:
	@bash scripts/barolens.sh $@ $(ARGS)
