#include <iostream>
#include <fstream>
#include <sstream>
#include <string>

int main(int argc, char* argv[]) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <master_file>" << std::endl;
        return 1;
    }

    std::string masterFile = argv[1];
    std::string outputFile = "filtered_" + masterFile;

    std::ifstream in(masterFile);
    if (!in.is_open()) {
        std::cerr << "❌ Could not open master file: " << masterFile << std::endl;
        return 1;
    }

    std::ofstream out(outputFile);
    if (!out.is_open()) {
        std::cerr << "❌ Could not open output file: " << outputFile << std::endl;
        return 1;
    }

    std::string line;
    getline(in, line); // skip header
    out << line << std::endl; // write header

    int totalCount = 0;
    int keptCount = 0;
    int removedCount = 0;

    while (getline(in, line)) {
        std::stringstream ss(line);
        std::string timestamp, lat_str, lon_str, pop_str, temp_str;
        getline(ss, timestamp, ',');
        getline(ss, lat_str, ',');
        getline(ss, lon_str, ',');
        getline(ss, pop_str, ',');
        getline(ss, temp_str, ',');

        totalCount++;
        try {
            double pop = std::stod(pop_str);
            if (pop > 0) {
                out << line << std::endl;
                keptCount++;
            } else {
                removedCount++;
            }
        } catch (...) {
            removedCount++;
        }
    }

    std::cout << "✅ Done. Output saved to " << outputFile << std::endl;
    std::cout << "Kept " << keptCount << " out of " << totalCount << " rows (" << removedCount << " removed)" << std::endl;
    return 0;
} 