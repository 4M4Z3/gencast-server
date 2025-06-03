#include <iostream>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <string>
#include <iomanip>
#include <cmath>

namespace fs = std::filesystem;

// Check if point is within US bounds
bool in_us_bounds(double lat, double lon) {
    // Round to 2 decimal places for consistent comparison
    lat = std::round(lat * 100.0) / 100.0;
    lon = std::round(lon * 100.0) / 100.0;
    return (lat >= 24.25 && lat <= 49.25) &&
           (lon >= -125.00 && lon <= -67.00);
}

int main(int argc, char* argv[]) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <master_file>" << std::endl;
        return 1;
    }

    std::string masterFile = argv[1];
    std::string outputFile = "us_" + masterFile;

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

    while (getline(in, line)) {
        std::stringstream ss(line);
        std::string timestamp;
        double lat, lon, pop, temp;
        char comma;

        getline(ss, timestamp, ',');
        ss >> lat >> comma >> lon >> comma >> pop >> comma >> temp;

        if (in_us_bounds(lat, lon)) {
            out << line << std::endl;
            keptCount++;
        }
        totalCount++;
    }

    std::cout << "✅ Done. Output saved to " << outputFile << std::endl;
    std::cout << "Kept " << keptCount << " out of " << totalCount << " locations" << std::endl;
    return 0;
} 