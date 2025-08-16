#!/usr/bin/env python3
"""
Generate CMux Tree test data matching the testbench format
"""
import os

def generate_lut_data():
    """Generate LUT data matching testbench deterministic pattern"""
    print("Generating LUT test data...")
    
    # Match testbench LUT pattern: value = (lut_idx * 16) + (k * 8) + n
    lut_data = []
    for lut_idx in range(1024):
        for k in range(2):  # K+1 = 2 (k=0,1)
            for n in range(1024):  # N_LVL1 = 1024
                value = (lut_idx * 16) + (k * 8) + n
                value &= 0xFFFFFFFF  # 32-bit mask
                lut_data.append(str(value))
    
    with open("lut_test_data.txt", "w") as f:
        f.write(" ".join(lut_data))
    
    print(f"Generated {len(lut_data)} LUT coefficients")
    print(f"Sample: LUT[0][0][0] = {lut_data[0]}")
    print(f"Sample: LUT[0][0][1] = {lut_data[1]}")
    print(f"Sample: LUT[1][0][0] = {lut_data[2048]}")

def generate_ggsw_data():
    """Generate GGSW control bits matching testbench pattern"""
    print("\nGenerating GGSW control bits (10-19)...")
    
    # Match testbench GGSW pattern: deterministic values for bits 10-19
    ggsw_data = []
    control_pattern = [1, 0, 1, 0, 1, 0, 1, 0, 1, 0]  # Expected pattern
    
    for bit_idx in range(10):  # bits 10-19
        # Generate control value: >500 for bit=1, <500 for bit=0
        if control_pattern[bit_idx] == 1:
            ggsw_value = 800  # > 500, so control_bit = true
        else:
            ggsw_value = 200  # < 500, so control_bit = false
            
        ggsw_data.append(str(ggsw_value))
        
        control_bit = (ggsw_value % 1000) > 500
        print(f"Bit {bit_idx+10}: ggsw_value={ggsw_value}, control_bit={control_bit}")
    
    with open("ggsw_test_data.txt", "w") as f:
        f.write(" ".join(ggsw_data))
    
    print(f"Generated {len(ggsw_data)} GGSW control values")
    return control_pattern

def calculate_expected_result(control_pattern):
    """Calculate expected LUT index based on control pattern"""
    print(f"\nCalculating expected result...")
    print(f"Control pattern: {control_pattern}")
    
    # Convert control bits to LUT index
    lut_index = 0
    for i, bit in enumerate(control_pattern):
        lut_index += bit * (2**i)
    
    print(f"Expected LUT index: {lut_index}")
    
    # Calculate expected result values: LUT[lut_index][k][n]
    expected_values = []
    for k in range(2):
        for n in range(4):  # Show first 4 coefficients
            value = (lut_index * 16) + (k * 8) + n
            value &= 0xFFFFFFFF
            expected_values.append(value)
            print(f"Expected a[{k}][{n}] = {value}")
    
    return lut_index, expected_values

if __name__ == "__main__":
    print("=== CMux Tree Test Data Generator ===")
    
    generate_lut_data()
    control_pattern = generate_ggsw_data()
    expected_index, expected_values = calculate_expected_result(control_pattern)
    
    print(f"\n=== Test Summary ===")
    print(f"LUT file: lut_test_data.txt")
    print(f"GGSW file: ggsw_test_data.txt")
    print(f"Control pattern: {control_pattern}")
    print(f"Expected LUT[{expected_index}] selection")
    print(f"Ready to run CMux test!")
