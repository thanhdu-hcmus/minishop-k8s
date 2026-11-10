{{- define "minishop.image" -}}
{{- $image := index .root.Values.images .name -}}
{{ printf "%s@%s" $image.repository $image.digest }}
{{- end -}}

{{/*
PostgreSQL and Redis connection settings for the backend and the seed Job.
Passwords come from the app credentials Secret through secretKeyRef only.
*/}}
{{- define "minishop.dataEnv" -}}
- name: POSTGRES_DB
  value: minishop
- name: POSTGRES_HOST
  value: minishop-postgresql.data.svc.cluster.local
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      key: postgres-password
      name: {{ .Values.credentials.appSecretName }}
- name: POSTGRES_PORT_NUM
  value: "5432"
- name: POSTGRES_USER
  value: minishop
- name: REDIS_HOST
  value: minishop-redis.data.svc.cluster.local
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      key: redis-password
      name: {{ .Values.credentials.appSecretName }}
- name: REDIS_PORT
  value: "6379"
{{- end -}}
