#include <iostream>
#include <filesystem>
#include <chrono>
#include <ctime>

namespace fs = std::filesystem;

std::string get_today_date() {
    auto now = std::chrono::system_clock::now();
    std::time_t t_now = std::chrono::system_clock::to_time_t(now);
    std::tm *ptm = std::localtime(&t_now);
    char buffer[16];
    std::strftime(buffer, 16, "%m-%d-%Y", ptm);
    return std::string(buffer);
}

int main(int argc, char* argv[]) {
    std::string date = (argc > 1) ? argv[1] : get_today_date();
    std::string folder = "./" + date;

    if (!fs::exists(folder)) {
        std::cerr << "❌ Directory does not exist: " << folder << "\n";
        return 1;
    }

    try {
        fs::remove_all(folder);
        std::cout << "🧹 Deleted folder: " << folder << "\n";
    } catch (const fs::filesystem_error& e) {
        std::cerr << "❌ Failed to delete folder: " << e.what() << "\n";
        return 1;
    }

    return 0;
}

