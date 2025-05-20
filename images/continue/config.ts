// replace ${VAR_NAME} placeholders with their process.env values
const replaceEnvVars = <T>(obj: T): T => {
  if (Array.isArray(obj)) {
    return obj.map(replaceEnvVars) as T;
  }

  if (!obj || typeof obj !== 'object') {
    return obj;
  }

  const result = { ...obj } as Record<string, any>;
  for (const key in result) {
    if (Object.prototype.hasOwnProperty.call(result, key)) {
      if (typeof result[key] === 'string') {
        result[key] = result[key].replace(/\$\{(.+?)\}/g, (_, varName) =>
          process.env[varName] ?? '');
      } else if (result[key] && typeof result[key] === 'object') {
        result[key] = replaceEnvVars(result[key]);
      }
    }
  }
  return result as T;
};

