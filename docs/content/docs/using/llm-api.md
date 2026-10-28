---
title: "LLM and speech APIs"
weight: 4
---

# LLM and speech APIs

All endpoints are OpenAI-compatible. Your API key is a JupyterHub API token:

- **Inside JupyterHub** it is already set as `JUPYTERHUB_API_TOKEN`:

  ```bash
  export API_KEY=$JUPYTERHUB_API_TOKEN
  ```

- **Anywhere else**, make a token at
  [jupyterhub.cirrus.carlboettiger.info/hub/token](https://jupyterhub.cirrus.carlboettiger.info/hub/token)
  and export it as `API_KEY`. Give it a note saying where it's used. Revoke it on the
  same page when you no longer need it.

A token works for as long as it is valid and you are a hub user, so leaving the lab
ends access.

## LLMs

Each model runs on its own GPU machine, and its endpoint is named after the
machine, not the model:

```
https://vllm-<machine>.carlboettiger.info/v1
```

for example `https://vllm-nimbus.carlboettiger.info/v1`. A machine runs one
model at a time, and which model that is changes over time. Ask the endpoint:

```bash
curl -s -H "Authorization: Bearer $API_KEY" https://vllm-nimbus.carlboettiger.info/v1/models
```

A `503` means that machine isn't serving a model right now.

```python
from openai import OpenAI
client = OpenAI(base_url="https://vllm-nimbus.carlboettiger.info/v1", api_key=API_KEY)
model = client.models.list().data[0].id
reply = client.chat.completions.create(
    model=model, messages=[{"role": "user", "content": "Hello"}])
```

Use the model id that `/v1/models` returns; don't hard-code one.

## Speech-to-text

`https://whisper-cirrus.carlboettiger.info/v1` serves OpenAI's audio
transcription API. Despite the hostname, it serves several speech-recognition
model families (Whisper and Parakeet). You pick one per request.

```bash
curl -s -H "Authorization: Bearer $API_KEY" \
  -F file=@talk.mp3 -F model=<model-id> \
  https://whisper-cirrus.carlboettiger.info/v1/audio/transcriptions
```

`GET /v1/models` lists the models currently loaded, and
`GET /v1/registry?task=automatic-speech-recognition` lists the ones that can be
loaded on request.
