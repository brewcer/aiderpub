#!/bin/bash
# Test models with COMPLEX real-world tasks

TEST_DIR="/tmp/complex_model_tests_$(date +%s)"
mkdir -p "$TEST_DIR"

echo "Testing models with COMPLEX tasks..."
echo "=========================================="
echo ""

# Models to test (best performers from previous test)
MODELS=(
    "phi-3-mini-128k-instruct_function.q8_0.gguf"
    "Meta-Llama-3.1-8B-Instruct-Q6_K_L.gguf"
    "qwen2.5-coder-3b-instruct-q8_0.gguf"
)

# Complex test scenarios
declare -A TEST_COMMANDS=(
    ["simple_file"]="create a file called test_simple.txt with the text 'hello world'"
    ["list_directory"]="list all directories in /home/aipc/ and save the output to test_directories.txt"
    ["system_info"]="create a Python script called test_sysinfo.py that prints CPU usage, memory usage, and disk space"
    ["flask_dashboard"]="create a simple Flask dashboard in a file called test_dashboard.py that shows system CPU and memory usage on a webpage"
)

cd /home/aipc/open-interpreter
source venv/bin/activate

for model in "${MODELS[@]}"; do
    model_path="/home/aipc/text-generation-webui/user_data/models/$model"
    
    if [ ! -f "$model_path" ]; then
        echo "⚠️  Model not found: $model"
        continue
    fi
    
    echo "=========================================="
    echo "Testing: $model"
    echo "=========================================="
    echo ""
    
    # Test each scenario
    for test_name in "${!TEST_COMMANDS[@]}"; do
        test_cmd="${TEST_COMMANDS[$test_name]}"
        echo "Test: $test_name"
        echo "Command: $test_cmd"
        echo "----------------------------------------"
        
        # Clean up any existing test files
        rm -f test_*.txt test_*.py
        
        # Start timing
        start_time=$(date +%s)
        
        # Run test with 3 minute timeout
        timeout 180 interpreter \
            --api_base http://localhost:8081/v1 \
            --model "$model_path" \
            --api_key "fake" \
            -y \
            --no-llm_supports_functions \
            --disable_telemetry \
            > "$TEST_DIR/${model}_${test_name}.log" 2>&1 <<EOF
$test_cmd
EOF
        
        exit_code=$?
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        # Count output lines (verbosity measure)
        output_lines=$(wc -l < "$TEST_DIR/${model}_${test_name}.log" 2>/dev/null || echo "0")
        
        # Check for computer.ai hallucinations
        hallucination_count=$(grep -c "computer\." "$TEST_DIR/${model}_${test_name}.log" 2>/dev/null || echo "0")
        
        # Check if expected output exists
        case $test_name in
            "simple_file")
                expected_file="test_simple.txt"
                ;;
            "list_directory")
                expected_file="test_directories.txt"
                ;;
            "system_info")
                expected_file="test_sysinfo.py"
                ;;
            "flask_dashboard")
                expected_file="test_dashboard.py"
                ;;
        esac
        
        if [ -f "$expected_file" ]; then
            file_created="✅"
            # Move to test directory
            cp "$expected_file" "$TEST_DIR/${model}_${test_name}_output"
        else
            file_created="❌"
        fi
        
        # Determine status
        if [ $exit_code -eq 0 ] && [ "$file_created" = "✅" ] && [ "$hallucination_count" -eq 0 ]; then
            status="✅ PERFECT"
        elif [ $exit_code -eq 0 ] && [ "$file_created" = "✅" ]; then
            status="⚠️  SUCCESS (with hallucinations: $hallucination_count)"
        elif [ $exit_code -eq 124 ]; then
            status="⏱️  TIMEOUT"
        else
            status="❌ FAILED"
        fi
        
        echo "Duration: ${duration}s"
        echo "Output lines: $output_lines"
        echo "File created: $file_created"
        echo "Hallucinations: $hallucination_count"
        echo "Status: $status"
        echo ""
        
        # Clean up test files
        rm -f test_*.txt test_*.py
    done
    
    echo ""
done

echo "=========================================="
echo "Test complete!"
echo "Full logs and outputs in: $TEST_DIR/"
echo ""

# Create detailed summary
cat > "$TEST_DIR/RESULTS.md" <<EOF
# Complex Model Test Results

**Date**: $(date)  
**Test Directory**: $TEST_DIR

## Test Scenarios

1. **simple_file**: Create a simple text file
2. **list_directory**: List directories and save to file
3. **system_info**: Create a Python script that shows system info
4. **flask_dashboard**: Create a Flask web dashboard

## Results Summary

EOF

for model in "${MODELS[@]}"; do
    echo "### $model" >> "$TEST_DIR/RESULTS.md"
    echo "" >> "$TEST_DIR/RESULTS.md"
    echo "| Test | Duration | Lines | Hallucinations | Status |" >> "$TEST_DIR/RESULTS.md"
    echo "|------|----------|-------|----------------|--------|" >> "$TEST_DIR/RESULTS.md"
    
    for test_name in "${!TEST_COMMANDS[@]}"; do
        if [ -f "$TEST_DIR/${model}_${test_name}.log" ]; then
            duration=$(grep "Duration:" "$TEST_DIR/${model}_${test_name}.log" 2>/dev/null | tail -1 | awk '{print $2}' || echo "N/A")
            lines=$(grep "Output lines:" "$TEST_DIR/${model}_${test_name}.log" 2>/dev/null | tail -1 | awk '{print $3}' || echo "N/A")
            hallucinations=$(grep "Hallucinations:" "$TEST_DIR/${model}_${test_name}.log" 2>/dev/null | tail -1 | awk '{print $2}' || echo "N/A")
            status=$(grep "Status:" "$TEST_DIR/${model}_${test_name}.log" 2>/dev/null | tail -1 | cut -d: -f2- || echo "N/A")
            
            echo "| $test_name | $duration | $lines | $hallucinations | $status |" >> "$TEST_DIR/RESULTS.md"
        fi
    done
    
    echo "" >> "$TEST_DIR/RESULTS.md"
done

cat >> "$TEST_DIR/RESULTS.md" <<EOF

## Analysis

- **✅ PERFECT**: Task completed without hallucinations
- **⚠️ SUCCESS**: Task completed but model hallucinated 'computer.*' functions
- **❌ FAILED**: Task did not complete or file not created
- **⏱️ TIMEOUT**: Exceeded 3 minute timeout

## Recommendation

The best model for complex tasks is the one with:
1. Most "PERFECT" results (no hallucinations)
2. Fastest completion times
3. Fewest output lines (least verbose)

Check the logs in $TEST_DIR/ for detailed output from each test.
EOF

echo "Results written to: $TEST_DIR/RESULTS.md"
cat "$TEST_DIR/RESULTS.md"