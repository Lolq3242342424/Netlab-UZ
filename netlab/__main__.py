"""Запуск: uv run python -m netlab [--port 8000]"""
import argparse

from .server import create_server


def main():
    parser = argparse.ArgumentParser(description="NetLab UZ — локальный сервер")
    parser.add_argument("--port", type=int, default=8000,
                        help="порт (по умолчанию 8000; 0 — выбрать свободный)")
    args = parser.parse_args()

    server = create_server("127.0.0.1", args.port)
    real_port = server.server_address[1]
    print(f"NetLab UZ: http://127.0.0.1:{real_port}  (Ctrl+C — остановить)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановлено.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()