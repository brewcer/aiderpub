#!/bin/bash
# Comprehensive Aider Model Testing Script
# Tests 5 models with progressively harder coding tasks

set -e

# Configuration
TEST_DIR="/tmp/aider_model_tests_$(date +%s)"
RESULTS_DIR="$TEST_DIR/results"
PROJECTS_DIR="$TEST_DIR/projects"
LLAMA_SERVER_PORT=8081
MODEL_BASE_PATH="/home/aipc/text-generation-webui/user_data/models"

# Models to test (ordered by expected performance)
MODELS=(
    "qwen2.5-coder-3b-instruct-q8_0.gguf"
    "deepseek-coder-5.7bmqa-base.Q8_0.gguf"
    "codellama-7b-instruct.Q8_0.gguf"
    "Meta-Llama-3.1-8B-Instruct-Q6_K_L.gguf"
    "gemma-3-4b-it.Q8_0.gguf"
)

# Test scenarios (progressively harder)
declare -A TEST_TASKS=(
    ["1_simple_flask"]="Create a Flask app in app.py with a single route / that returns 'Hello World'"
    ["2_config_file"]="Add a config.py file that loads settings from environment variables (PORT, DEBUG, SECRET_KEY) with defaults"
    ["3_refactor_routes"]="Refactor app.py to use Flask blueprints. Move the hello route to a new file routes/main.py"
    ["4_add_api"]="Add a REST API endpoint /api/data that returns JSON with current timestamp and system uptime"
    ["5_error_handling"]="Add comprehensive error handling with custom 404 and 500 error pages as templates"
)

# Setup
mkdir -p "$TEST_DIR" "$RESULTS_DIR" "$PROJECTS_DIR"

echo "=================================="
echo "AIDER MODEL TESTING SUITE"
echo "=================================="
echo "Test Directory: $TEST_DIR"
echo "Testing $(echo ${MODELS[@]} | wc -w) models"
echo "$(echo ${TEST_TASKS[@]} | wc -w) tasks per model"
echo "Timeout: 5 minutes per task"
echo ""

# Function to start llama.cpp server
start_llama_server() {
    local model_path="$1"
    local model_name=$(basename "$model_path")
    
    echo "Starting llama.cpp server with $model_name..."
    
    # Kill any existing server
    pkill -f llama-server || true
    sleep 2
    
    # Start new server
    llama-server \
        --model "$model_path" \
        --host 0.0.0.0 \
        --port $LLAMA_SERVER_PORT \
        --ctx-size 4096 \
        --n-gpu-layers 99 \
        > "$RESULTS_DIR/server_${model_name}.log" 2>&1 &
    
    local server_pid=$!
    
    # Wait for server to be ready
    echo "Waiting for server to start..."
    for i in {1..30}; do
        if curl -s http://localhost:$LLAMA_SERVER_PORT/v1/models > /dev/null 2>&1; then
            echo "✅ Server ready (PID: $server_pid)"
            return 0
        fi
        sleep 2
    done
    
    echo "❌ Server failed to start"
    return 1
}

# Function to run Aider test
run_aider_test() {
    local model_name="$1"
    local task_name="$2"
    local task_prompt="$3"
    local project_dir="$4"
    
    echo ""
    echo "Task: $task_name"
    echo "Prompt: $task_prompt"
    echo "---"
    
    local log_file="$RESULTS_DIR/${model_name}_${task_name}.log"
    local start_time=$(date +%s)
    
    cd "$project_dir"
    
    # Run Aider with timeout
    timeout 300 aider \
        --openai-api-base http://localhost:$LLAMA_SERVER_PORT/v1 \
        --openai-api-key fake \
        --model openai/gpt-3.5-turbo \
        --yes \
        --no-show-model-warnings \
        --message "$task_prompt" \
        > "$log_file" 2>&1
    
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Analyze results
    local files_created=$(git ls-files | wc -l)
    local commits_made=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    local output_lines=$(wc -l < "$log_file")
    
    # Check for errors
    local errors=$(grep -i "error\|exception\|failed" "$log_file" | wc -l)
    
    # Determine status
    local status="❌ FAILED"
    if [ $exit_code -eq 124 ]; then
        status="⏱️  TIMEOUT"
    elif [ $exit_code -eq 0 ] && [ $files_created -gt 0 ]; then
        if [ $errors -eq 0 ]; then
            status="✅ SUCCESS"
        else
            status="⚠️  SUCCESS (with errors)"
        fi
    fi
    
    echo "Duration: ${duration}s"
    echo "Files: $files_created"
    echo "Commits: $commits_made"
    echo "Output lines: $output_lines"
    echo "Errors detected: $errors"
    echo "Status: $status"
    
    # Save metrics
    echo "$model_name,$task_name,$duration,$files_created,$commits_made,$errors,$status" \
        >> "$RESULTS_DIR/metrics.csv"
}

# Function to validate project
validate_project() {
    local project_dir="$1"
    local model_name="$2"
    
    cd "$project_dir"
    
    echo ""
    echo "Validating project..."
    
    # Check if Flask app runs
    if [ -f "app.py" ]; then
        echo "Checking Python syntax..."
        python3 -m py_compile app.py 2>&1 | tee "$RESULTS_DIR/${model_name}_validation.log"
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "✅ Python syntax valid"
        else
            echo "❌ Python syntax errors"
        fi
    fi
    
    # Check file structure
    echo ""
    echo "Project structure:"
    tree -L 2 || ls -lhR
}

# Initialize CSV
echo "model,task,duration_seconds,files_created,commits_made,errors,status" \
    > "$RESULTS_DIR/metrics.csv"

# Main testing loop
for model in "${MODELS[@]}"; do
    model_path="$MODEL_BASE_PATH/$model"
    
    if [ ! -f "$model_path" ]; then
        echo "⚠️  Model not found: $model"
        continue
    fi
    
    echo ""
    echo "=========================================="
    echo "Testing Model: $model"
    echo "=========================================="
    
    # Start server for this model
    if ! start_llama_server "$model_path"; then
        echo "Skipping model due to server failure"
        continue
    fi
    
    # Create fresh project directory
    model_project_dir="$PROJECTS_DIR/${model%.gguf}_project"
    mkdir -p "$model_project_dir"
    cd "$model_project_dir"
    git init > /dev/null 2>&1
    git config user.name "Aider Test"
    git config user.email "test@aider.local"
    
    # Run all tasks in sequence
    for task_key in $(echo "${!TEST_TASKS[@]}" | tr ' ' '\n' | sort); do
        run_aider_test "$model" "$task_key" "${TEST_TASKS[$task_key]}" "$model_project_dir"
    done
    
    # Validate final project
    validate_project "$model_project_dir" "$model"
    
    # Archive the project
    cd "$PROJECTS_DIR"
    tar -czf "${model%.gguf}_project.tar.gz" "${model%.gguf}_project"
    
    echo ""
    echo "✅ Model testing complete"
done

# Kill server
pkill -f llama-server || true

# Generate comprehensive report
echo ""
echo "=========================================="
echo "GENERATING REPORT"
echo "=========================================="

cat > "$RESULTS_DIR/REPORT.md" <<EOF
# Aider Model Testing Report

**Date**: $(date)  
**Test Directory**: $TEST_DIR

## Test Configuration

- **Models Tested**: ${#MODELS[@]}
- **Tasks Per Model**: ${#TEST_TASKS[@]}
- **Timeout**: 5 minutes per task
- **Total Test Time**: ~$(( ${#MODELS[@]} * ${#TEST_TASKS[@]} * 5 )) minutes max

## Models

$(for model in "${MODELS[@]}"; do
    echo "- $model"
done)

## Test Tasks

$(for task_key in $(echo "${!TEST_TASKS[@]}" | tr ' ' '\n' | sort); do
    echo "$task_key: ${TEST_TASKS[$task_key]}"
done)

## Results Summary

### Performance Matrix

| Model | Task 1 | Task 2 | Task 3 | Task 4 | Task 5 | Avg Time | Success Rate |
|-------|--------|--------|--------|--------|--------|----------|--------------|
EOF

# Calculate summary stats per model
for model in "${MODELS[@]}"; do
    model_name="${model%.gguf}"
    
    # Get all task results for this model
    task1=$(grep "^$model,1_simple_flask" "$RESULTS_DIR/metrics.csv" | cut -d',' -f7 || echo "N/A")
    task2=$(grep "^$model,2_config_file" "$RESULTS_DIR/metrics.csv" | cut -d',' -f7 || echo "N/A")
    task3=$(grep "^$model,3_refactor_routes" "$RESULTS_DIR/metrics.csv" | cut -d',' -f7 || echo "N/A")
    task4=$(grep "^$model,4_add_api" "$RESULTS_DIR/metrics.csv" | cut -d',' -f7 || echo "N/A")
    task5=$(grep "^$model,5_error_handling" "$RESULTS_DIR/metrics.csv" | cut -d',' -f7 || echo "N/A")
    
    # Calculate average time
    avg_time=$(grep "^$model," "$RESULTS_DIR/metrics.csv" | cut -d',' -f3 | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print "N/A"}')
    
    # Calculate success rate
    successes=$(grep "^$model," "$RESULTS_DIR/metrics.csv" | cut -d',' -f7 | grep -c "SUCCESS" || echo "0")
    total=$(grep "^$model," "$RESULTS_DIR/metrics.csv" | wc -l)
    if [ $total -gt 0 ]; then
        success_rate=$(echo "scale=0; ($successes * 100) / $total" | bc)"%"
    else
        success_rate="N/A"
    fi
    
    echo "| $model_name | $task1 | $task2 | $task3 | $task4 | $task5 | ${avg_time}s | $success_rate |" >> "$RESULTS_DIR/REPORT.md"
done

cat >> "$RESULTS_DIR/REPORT.md" <<EOF

## Detailed Metrics

\`\`\`csv
$(cat "$RESULTS_DIR/metrics.csv")
\`\`\`

## Analysis

### Best Overall Model
$(grep "^" "$RESULTS_DIR/metrics.csv" | cut -d',' -f1 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

### Fastest Average Time
$(tail -n +2 "$RESULTS_DIR/metrics.csv" | sort -t',' -k3 -n | head -1 | cut -d',' -f1)

### Most Reliable (Least Errors)
$(tail -n +2 "$RESULTS_DIR/metrics.csv" | sort -t',' -k6 -n | head -1 | cut -d',' -f1)

## Recommendations

Based on the test results:

1. **For simple tasks**: Use the fastest model
2. **For complex refactoring**: Use the most reliable model
3. **For daily use**: Best balance of speed and accuracy

## Test Artifacts

- Full logs: \`$RESULTS_DIR/\`
- Project archives: \`$PROJECTS_DIR/*.tar.gz\`
- Raw metrics: \`$RESULTS_DIR/metrics.csv\`

---

**Next Steps**: Review individual task logs in \`$RESULTS_DIR/\` to see exactly how each model performed.
EOF

echo ""
cat "$RESULTS_DIR/REPORT.md"

echo ""
echo "=========================================="
echo "TEST COMPLETE!"
echo "=========================================="
echo "Results: $RESULTS_DIR/REPORT.md"
echo "Logs: $RESULTS_DIR/"
echo "Projects: $PROJECTS_DIR/"
echo ""
echo "To review:"
echo "  cat $RESULTS_DIR/REPORT.md"
echo "  ls -lh $RESULTS_DIR/"
echo ""
