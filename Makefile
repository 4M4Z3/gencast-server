# Detect OS
ifeq ($(OS),Windows_NT)
    CC = g++
    RM = del /Q /F
    EXE = .exe
    POWERSHELL = powershell -ExecutionPolicy Bypass -File
    SAVE_QUERY = $(POWERSHELL) save_query.ps1
else
    CC = g++
    RM = rm -f
    EXE =
    SAVE_QUERY = ./save_query.sh
endif

# Compiler flags
CFLAGS = -std=c++17 -Wall

# Targets
all: merge$(EXE) filter_nonzero_population$(EXE) delete_data$(EXE)

merge$(EXE): merge.cpp
	$(CC) $(CFLAGS) -o merge$(EXE) merge.cpp

filter_nonzero_population$(EXE): filter_nonzero_population.cpp
	$(CC) $(CFLAGS) -o filter_nonzero_population$(EXE) filter_nonzero_population.cpp

delete_data$(EXE): delete_data.cpp
	$(CC) $(CFLAGS) -o delete_data$(EXE) delete_data.cpp

run: all
	@echo "Running complete workflow..."
	@echo "1. Fetching data from BigQuery..."
	$(SAVE_QUERY)
	@echo "2. Processing data with merge program..."
	./merge$(EXE)
	@echo "3. Filtering out zero-population points..."
	./filter_nonzero_population$(EXE) master_$(shell date +%m-%d-%Y).csv
	@echo "4. Cleaning up temporary files..."
	./delete_data$(EXE)
	@echo "Workflow complete!"

run-no-delete: all
	@echo "Running workflow without cleanup..."
	@echo "1. Fetching data from BigQuery..."
	$(SAVE_QUERY)
	@echo "2. Processing data with merge program..."
	./merge$(EXE)
	@echo "3. Filtering out zero-population points..."
	./filter_nonzero_population$(EXE) master_$(shell date +%m-%d-%Y).csv
	@echo "Workflow complete! (Data files preserved)"

clean:
	$(RM) merge$(EXE) filter_nonzero_population$(EXE) delete_data$(EXE)
	$(RM) filtered_master_*.csv ready_for_upload.csv

.PHONY: all clean run run-no-delete 