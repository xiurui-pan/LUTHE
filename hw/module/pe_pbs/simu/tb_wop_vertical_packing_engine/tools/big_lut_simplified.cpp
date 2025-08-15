#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc < 6) {
        fprintf(stderr, "Usage: %s <lut_txt> <bits_txt> <out_txt> <N> <LUT_SIZE>\n", argv[0]);
        return 1;
    }
    string lut_path = argv[1];
    string bits_path = argv[2];
    string out_path = argv[3];
    int N = atoi(argv[4]);
    int LUT_SIZE = atoi(argv[5]);

    // Read bits (20 lines of 0/1)
    vector<int> bits;
    {
        ifstream fin(bits_path);
        if (!fin) { fprintf(stderr, "Failed to open bits file\n"); return 2; }
        int v; while (fin >> v) { bits.push_back(v & 1); }
        fin.close();
        if ((int)bits.size() < 20) { fprintf(stderr, "bits size < 20\n"); return 3; }
    }

    // Read LUT: LUT_SIZE lines, each has N integers (k=0 poly only)
    vector<vector<int>> lut(LUT_SIZE, vector<int>(N, 0));
    {
        ifstream fin(lut_path);
        if (!fin) { fprintf(stderr, "Failed to open lut file\n"); return 4; }
        for (int i = 0; i < LUT_SIZE; i++) {
            for (int n = 0; n < N; n++) {
                int x; if (!(fin >> x)) { fprintf(stderr, "LUT file format error at i=%d n=%d\n", i, n); return 5; }
                lut[i][n] = x;
            }
        }
        fin.close();
    }

    // 1) Build CMux index from bits[10..19]
    int idx = 0;
    for (int d = 10; d < 20; d++) {
        idx = (idx << 1) | (bits[d] & 1);
    }

    // 2) Rotation shift from bits[0..9]
    long long rot = 0;
    for (int d = 0; d < 10; d++) if (bits[d]) rot += (1LL << d);
    rot %= N;

    // 3) Sample extract mapping
    vector<long long> golden(N, 0);
    for (int i = 0; i < N; i++) {
        if (i == 0) {
            int src = (0 + rot) % N;
            golden[i] = lut[idx][src];
        } else {
            int src = (N - i + rot) % N;
            golden[i] = - (long long)lut[idx][src];
        }
    }

    // Write output (N lines)
    ofstream fout(out_path);
    if (!fout) { fprintf(stderr, "Failed to open out file\n"); return 6; }
    for (int i = 0; i < N; i++) fout << golden[i] << '\n';
    fout.close();
    return 0;
}



