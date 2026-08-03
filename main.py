import os
import sys
from openai import OpenAI

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

LOCAL_API_URL = os.getenv("LOCAL_API_URL", "http://127.0.0.1:12345/v1")
LOCAL_MODEL = os.getenv("LOCAL_MODEL", "devstral-small-2:24b")
API_KEY = os.getenv("OPENAI_API_KEY", "ollama")

client = OpenAI(
    base_url=LOCAL_API_URL,
    api_key=API_KEY
)

def list_models():
    try:
        import requests
        r = requests.get(LOCAL_API_URL.replace("/v1", "/api/tags"), timeout=10)
        if r.ok:
            return [m["name"] for m in r.json().get("models", [])]
    except Exception:
        pass
    return []

def chat_with_local_ai(prompt, model=None):
    model = model or LOCAL_MODEL
    print(f"Model: {model}")
    print(f"Endpoint: {LOCAL_API_URL}")
    print(f"Prompt: '{prompt}'\n")
    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": "You are a helpful, smart, and friendly AI assistant."},
                {"role": "user", "content": prompt}
            ],
            temperature=0.7,
        )
        print("AI Response:")
        print(response.choices[0].message.content)
    except Exception as e:
        print(f"Error connecting to local AI: {e}")
        print()

        models = list_models()
        if models:
            print("Available models on server:")
            for m in models:
                print(f"  - {m}")
        print()
        print("Troubleshooting:")
        print("  1. Run: ollama list")
        print("  2. Start Ollama: ollama serve")
        print("  3. Set LOCAL_API_URL env var (default: http://127.0.0.1:12345/v1)")
        print("  4. Set LOCAL_MODEL env var to a model from 'ollama list'")

if __name__ == "__main__":
    print("=== Local AI Tester ===")
    print(f"Endpoint: {LOCAL_API_URL}")
    print(f"Default model: {LOCAL_MODEL}")

    if "--list" in sys.argv:
        print()
        models = list_models()
        if models:
            print("Models on server:")
            for m in models:
                print(f"  - {m}")
        else:
            print("Could not reach Ollama API. Is it running?")
        sys.exit(0)

    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        user_input = " ".join(sys.argv[1:])
    else:
        user_input = input("\nEnter a message for the AI (or press Enter for default): ")

    if not user_input.strip():
        user_input = "Explain the concept of local LLMs in two short sentences."

    print()
    chat_with_local_ai(user_input)
