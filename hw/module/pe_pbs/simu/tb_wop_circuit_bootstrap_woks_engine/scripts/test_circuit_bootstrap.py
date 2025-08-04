#!/usr/bin/env python3
"""
Comprehensive test script for Circuit Bootstrap WoKS Engine
Generates multiple test cases and verifies RTL against golden reference
"""

import os
import sys
import subprocess
import random
import json

def generate_test_case(test_id, n_lvl0=4, n_lvl2=8, ell_lvl2=1):
    """Generate a test case with specific parameters"""
    
    # Generate mu parameter (message to bootstrap)
    mu_values = [
        0x8000000000000000,  # Standard high bit
        0x4000000000000000,  # Quarter bit  
        0x0000000000000000,  # Zero
        0xFFFFFFFFFFFFFFFF,  # All ones
        0x1234567890ABCDEF,  # Random pattern
    ]
    
    mu = mu_values[test_id % len(mu_values)]
    
    # Generate abar array (pre-modswitch result)
    abar = []
    for i in range(n_lvl0 + 1):
        if i == n_lvl0:  # bbar (last element)
            abar.append(random.randint(0, 2 * n_lvl2 - 1))
        else:  # aibar elements
            abar.append(random.randint(0, 2 * n_lvl2 - 1))
    
    return {
        'test_id': test_id,
        'mu': mu,
        'abar': abar,
        'n_lvl0': n_lvl0,
        'n_lvl2': n_lvl2,
        'ell_lvl2': ell_lvl2
    }

def run_test_case(test_case, timeout=60):
    """Run a single test case and return results"""
    
    test_id = test_case['test_id']
    print(f"Running Test Case {test_id}:")
    print(f"  mu: 0x{test_case['mu']:016x}")
    print(f"  abar: {[hex(x) for x in test_case['abar']]}")
    print(f"  params: n_lvl0={test_case['n_lvl0']}, n_lvl2={test_case['n_lvl2']}, ell={test_case['ell_lvl2']}")
    
    # Create test directory
    test_dir = f"test_case_{test_id}"
    os.makedirs(test_dir, exist_ok=True)
    
    # Save test case
    with open(f"{test_dir}/test_params.json", 'w') as f:
        json.dump(test_case, f, indent=2)
    
    try:
        # Run simulation with specific parameters
        cmd = [
            './run_circuit_bootstrap.sh',
            '-0', str(test_case['n_lvl0']),
            '-2', str(test_case['n_lvl2']),
            '-E', str(test_case['ell_lvl2'])
        ]
        
        env = os.environ.copy()
        env['CB_TEST_MU'] = f"0x{test_case['mu']:016x}"
        env['CB_TEST_ABAR'] = ','.join([str(x) for x in test_case['abar']])
        
        result = subprocess.run(
            cmd, 
            timeout=timeout, 
            capture_output=True, 
            text=True,
            env=env,
            cwd=os.getcwd()
        )
        
        # Save outputs
        with open(f"{test_dir}/stdout.log", 'w') as f:
            f.write(result.stdout)
        with open(f"{test_dir}/stderr.log", 'w') as f:
            f.write(result.stderr)
        
        # Parse results
        success = result.returncode == 0
        output_lines = result.stdout.split('\n')
        
        # Extract key information
        compilation_success = not any('ERROR' in line for line in output_lines)
        simulation_started = any('Starting simulation' in line for line in output_lines)
        golden_called = any('[CPP_GOLDEN]' in line for line in output_lines)
        
        return {
            'test_id': test_id,
            'success': success,
            'compilation_success': compilation_success,
            'simulation_started': simulation_started,
            'golden_called': golden_called,
            'output_file': f"{test_dir}/stdout.log"
        }
        
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT: Test {test_id} exceeded {timeout}s")
        return {
            'test_id': test_id,
            'success': False,
            'error': 'timeout',
            'output_file': None
        }
    except Exception as e:
        print(f"  ERROR: Test {test_id} failed with exception: {e}")
        return {
            'test_id': test_id,
            'success': False,
            'error': str(e),
            'output_file': None
        }

def analyze_results(results):
    """Analyze test results and generate report"""
    
    total_tests = len(results)
    passed_tests = sum(1 for r in results if r['success'])
    
    print(f"\n=== TEST SUMMARY ===")
    print(f"Total Tests: {total_tests}")
    print(f"Passed: {passed_tests}")
    print(f"Failed: {total_tests - passed_tests}")
    print(f"Success Rate: {passed_tests/total_tests*100:.1f}%")
    
    print(f"\n=== DETAILED RESULTS ===")
    for result in results:
        status = "PASS" if result['success'] else "FAIL"
        print(f"Test {result['test_id']:2d}: {status}")
        
        if not result['success']:
            if 'error' in result:
                print(f"          Error: {result['error']}")
            if 'output_file' in result and result['output_file']:
                print(f"          Log: {result['output_file']}")
    
    # Identify common failure patterns
    failed_results = [r for r in results if not r['success']]
    if failed_results:
        print(f"\n=== FAILURE ANALYSIS ===")
        compilation_failures = sum(1 for r in failed_results if not r.get('compilation_success', True))
        simulation_failures = sum(1 for r in failed_results if r.get('compilation_success', False) and not r.get('simulation_started', False))
        
        if compilation_failures > 0:
            print(f"Compilation Failures: {compilation_failures}")
        if simulation_failures > 0:
            print(f"Simulation Failures: {simulation_failures}")

def main():
    """Main test runner"""
    print("=== Circuit Bootstrap WoKS Comprehensive Testing ===")
    
    # Check if we're in the right directory
    if not os.path.exists('./run_circuit_bootstrap.sh'):
        print("ERROR: run_circuit_bootstrap.sh not found. Run from scripts directory.")
        sys.exit(1)
    
    # Generate test cases
    test_cases = []
    
    # Basic parameter sweep
    for test_id in range(5):
        test_cases.append(generate_test_case(test_id, n_lvl0=4, n_lvl2=8, ell_lvl2=1))
    
    # Different parameter configurations
    configs = [
        (4, 16, 1),
        (8, 8, 1), 
        (2, 4, 1),
    ]
    
    for i, (n0, n2, ell) in enumerate(configs):
        test_cases.append(generate_test_case(100 + i, n0, n2, ell))
    
    print(f"Generated {len(test_cases)} test cases")
    
    # Run tests
    results = []
    for i, test_case in enumerate(test_cases):
        print(f"\n--- Test {i+1}/{len(test_cases)} ---")
        result = run_test_case(test_case)
        results.append(result)
        
        # Short break between tests
        if i < len(test_cases) - 1:
            print("Waiting 2s before next test...")
            import time
            time.sleep(2)
    
    # Analyze and report
    analyze_results(results)
    
    # Save detailed report
    with open('test_report.json', 'w') as f:
        json.dump({
            'test_cases': test_cases,
            'results': results,
            'summary': {
                'total': len(results),
                'passed': sum(1 for r in results if r['success']),
                'failed': sum(1 for r in results if not r['success'])
            }
        }, f, indent=2)
    
    print(f"\nDetailed report saved to test_report.json")

if __name__ == '__main__':
    main()