#include <iostream>
#include <fstream>
#include <sstream>
#include <unordered_map>
#include <filesystem>
#include <iomanip>
#include <chrono>
#include <ctime>
#include <cmath>

namespace fs = std::filesystem;

struct LatLon {
    double lat, lon;
    bool operator==(const LatLon &other) const {
        // Use a small tolerance for floating point comparison
        const double EPSILON = 0.000001;
        return std::abs(lat - other.lat) < EPSILON && 
               std::abs(lon - other.lon) < EPSILON;
    }
};

namespace std {
    template <>
    struct hash<LatLon> {
        size_t operator()(const LatLon& k) const {
            // Round to 6 decimal places to ensure consistent hashing
            double lat = std::round(k.lat * 1000000) / 1000000;
            double lon = std::round(k.lon * 1000000) / 1000000;
            return hash<double>()(lat) ^ (hash<double>()(lon) << 1);
        }
    };
}

std::string get_today_date() {
    auto now = std::chrono::system_clock::now();
    std::time_t t_now = std::chrono::system_clock::to_time_t(now);
    std::tm *ptm = std::localtime(&t_now);
    char buffer[16];
    std::strftime(buffer, 16, "%m-%d-%Y", ptm);
    return std::string(buffer);
}

// Check if point is within US bounds
bool in_us_bounds(double lat, double lon) {
    return (lat >= 24.25 && lat <= 49.25) &&
           (lon >= -125.00 && lon <= -67.00);
}

int main(int argc, char* argv[]) {
    std::string date = (argc > 1) ? argv[1] : get_today_date();
    std::string folder = "./" + date;
    std::string popFilePath = "population_2020.csv";

    if (!fs::exists(folder)) {
        std::cerr << "❌ Directory does not exist: " << folder << "\n";
        return 1;
    }

    std::unordered_map<LatLon, double> populationMap;
    std::ifstream popFile(popFilePath);
    if (!popFile.is_open()) {
        std::cerr << "❌ Could not open population file: " << popFilePath << "\n";
        return 1;
    }

    // Debug: Print first few population entries
    std::cout << "Reading population data...\n";
    std::string line;
    getline(popFile, line); // skip header
    int popCount = 0;
    while (getline(popFile, line)) {
        std::stringstream ss(line);
        double lon, lat, pop;
        char comma;
        ss >> lon >> comma >> lat >> comma >> pop;
        // Fuzzy match: round to 2 decimal places
        lat = std::round(lat * 100.0) / 100.0;
        lon = std::round(lon * 100.0) / 100.0;
        // Swap lat and lon when storing in the map
        populationMap[{lat, lon}] = pop;
        
        // Print first 5 entries
        if (popCount < 5) {
            std::cout << "Population entry: lat=" << lat << ", lon=" << lon << ", pop=" << pop << "\n";
            popCount++;
        }
    }
    std::cout << "Total population entries: " << populationMap.size() << "\n";

    std::ofstream out("master_" + date + ".csv");
    out << "forecast_time,latitude,longitude,population,temp_2m,temp_2m_stddev\n";

    int matchCount = 0;
    int totalCount = 0;

    std::string prefix = date.substr(0, 2) + "_" + date.substr(3, 2) + "_" + date.substr(6, 4);
    std::cout << "Looking for files with prefix: " << prefix << std::endl;
    for (const auto& entry : fs::directory_iterator(folder)) {
        const std::string filename = entry.path().filename().string();
        std::cout << "Found file: " << filename << std::endl;
        if (filename.rfind(prefix, 0) == 0) {
            std::ifstream forecastFile(entry.path());
            std::string row;
            getline(forecastFile, row); // skip header
            while (getline(forecastFile, row)) {
                std::stringstream ss(row);
                std::string timestamp;
                double lat, lon, temp, temp_stddev;
                char comma;

                getline(ss, timestamp, ',');
                ss >> lat >> comma >> lon >> comma >> temp >> comma >> temp_stddev;

                // Convert forecast longitude to 0-360 system
                if (lon < 0) lon += 360.0;
                // Fuzzy match: round to 2 decimal places
                lat = std::round(lat * 100.0) / 100.0;
                lon = std::round(lon * 100.0) / 100.0;

                // Process all points regardless of US bounds
                LatLon key{lat, lon};
                if (populationMap.count(key)) {
                    out << std::fixed << std::setprecision(6)
                        << timestamp << "," 
                        << lat << "," 
                        << lon << "," 
                        << populationMap[key] << "," 
                        << temp << ","
                        << temp_stddev << "\n";
                    matchCount++;
                }
                totalCount++;
            }
        }
    }

    std::cout << "✅ Done. Output saved to master_" << date << ".csv\n";
    std::cout << "Matched " << matchCount << " out of " << totalCount << " locations\n";
    return 0;
}

