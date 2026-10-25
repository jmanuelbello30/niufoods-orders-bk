# Niu Foods Orders - API

## 1. Qué hace el proyecto

Este proyecto permite enviar una orden a un restaurante y comprobar si la tienda
la recibió. Por ejemplo, puedes pedir dos unidades de un producto, ver el total
calculado y encontrar esa misma orden en la pantalla de la tienda simulada.

La API es la parte del sistema que recibe las solicitudes. Revisa que los datos
sean válidos, calcula el monto con los precios del catálogo y guarda la orden.
Después de guardarla, el programa que ejecuta la API, envía la orden a la
tienda simulada. PostgreSQL se encarga de guardar los datos, no de enviarlos.

Para recorrer el proyecto usarás dos páginas:

- **Swagger:** permite iniciar sesión y enviar una orden desde el navegador.
- **Tienda simulada:** muestra las órdenes que realmente aceptó el receptor local.

También existe un [frontend Angular independiente](https://github.com/jmanuelbello30/niufoods-orders-ft)
con login, listado, detalle y reintento de envío. Es una interfaz adicional;
no necesitas instalarla para enviar una orden con Swagger y verla en la tienda.

## 2. Instalación desde cero

**Lee un paso, copia su comando, presiona enter y espera a que termine antes de
continuar.** Si un comando ocupa varias líneas, copia el bloque completo: sigue
siendo una sola instrucción.

Cuando un comando empiece con `sudo`, puede pedir la contraseña de tu computador
o de Ubuntu. Mientras la escribes, es normal que no aparezcan letras ni asteriscos.
Si pregunta si deseas continuar con una instalación, revisa la pregunta y confirma.

Elige tu sistema:

- [Windows](#windows): primero instalarás Ubuntu dentro de Windows.
- [Ubuntu](#ubuntu): prepararás las herramientas directamente en Ubuntu.
- [macOS](#macos): usarás Terminal y Homebrew para instalar las herramientas.

Las instrucciones están pensadas para un equipo local de evaluación. Si ya tienes
PostgreSQL u otro proyecto instalado, no borres ni reemplaces sus datos.

### Windows

**Paso 1. Abrir PowerShell como administrador.**

Abre Inicio, busca **PowerShell**, haz clic derecho y elige **Ejecutar como administrador**.
Acepta el permiso que solicite Windows.

**Paso 2. Instalar Ubuntu con WSL.**

WSL permite ejecutar Ubuntu dentro de Windows. Usaremos Ubuntu para todos los
comandos del backend, evitando tener que configurar Ruby directamente en Windows.

```powershell
wsl --install -d Ubuntu
```

Espera a que termine. Si Windows solicita reiniciar el computador, hazlo.

**Paso 3. Comprobar que se instaló WSL 2.**

Vuelve a abrir PowerShell y ejecuta:

```powershell
wsl --list --verbose
```

Busca la fila de Ubuntu: en la columna `VERSION` debe aparecer `2`.
Las instalaciones nuevas usan esa versión. Si aparece `1`, conviértela con:

```powershell
wsl --set-version Ubuntu 2
```

**Paso 4. Abrir Ubuntu y crear su usuario.**

Busca **Ubuntu** en Inicio y ábrelo. La primera vez te pedirá un nombre de usuario
y una contraseña. Guárdalos: la contraseña se usará para autorizar instalaciones
dentro de Ubuntu. Esta cuenta todavía no es la cuenta para entrar a Niu Foods.

A partir de ahora ejecuta los comandos del backend en la ventana de **Ubuntu**,
no en PowerShell. Continúa con la sección **Ubuntu** que sigue. No necesitas
realizar la sección macOS.

Si Windows no permite instalar WSL, consulta los requisitos y soluciones de la
[guía oficial de Microsoft](https://learn.microsoft.com/en-us/windows/wsl/install).

### Ubuntu

Estos pasos sirven tanto para Ubuntu instalado directamente como para Ubuntu
dentro de Windows. En Ubuntu nativo abre **Terminal**; normalmente puedes hacerlo
con `Ctrl+Alt+T`. En Windows usa la aplicación **Ubuntu** del paso anterior.

**Paso 1. Actualizar la lista de programas disponibles.**

Esto permite que Ubuntu conozca los paquetes que puede descargar. Todavía no
instala las herramientas del proyecto.

```sh
sudo apt update
```

**Paso 2. Instalar las herramientas necesarias.**

Este comando instala Git para descargar el proyecto, curl para descargar
instaladores y las bibliotecas necesarias para preparar Ruby y sus complementos.
La instalación puede tardar varios minutos.

```sh
sudo apt install build-essential autoconf libssl-dev libyaml-dev zlib1g-dev \
  libffi-dev libgmp-dev rustc curl ca-certificates git tzdata libvips-dev
```

**Paso 3. Instalar mise.**

Mise es una herramienta que nos ayudará a instalar la versión de Ruby que utiliza
el proyecto. El comando descarga y ejecuta su instalador oficial.

```sh
curl -fsSL https://mise.run | sh
```

**Paso 4. Activar mise en esta terminal.**

Esto permite usar las herramientas instaladas por mise en la ventana actual.
Si luego abres otra terminal, tendrás que repetir esta activación allí.

```sh
eval "$(~/.local/bin/mise activate bash)"
```

**Paso 5. Instalar la herramienta de configuración de PostgreSQL.**

PostgreSQL es el programa que guardará las órdenes. Primero instalamos una
herramienta oficial que permite agregar su fuente de descarga.

```sh
sudo apt install postgresql-common
```

**Paso 6. Agregar la fuente oficial de PostgreSQL.**

Esto permite instalar PostgreSQL 18 aunque esa versión no esté incluida en los
paquetes predeterminados de tu Ubuntu. Lee y confirma lo que solicite el asistente.

```sh
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
```

**Paso 7. Actualizar la lista de programas una vez más.**

Ahora Ubuntu incorporará los paquetes de la fuente que acabas de agregar.

```sh
sudo apt update
```

**Paso 8. Instalar PostgreSQL.**

Se instalan la base de datos, sus herramientas de conexión y una biblioteca que
puede necesitar Ruby para comunicarse con ella.

```sh
sudo apt install postgresql-18 postgresql-client-18 libpq-dev
```

**Paso 9. Encender PostgreSQL.**

El programa debe permanecer activo para que la API pueda guardar y consultar órdenes.

```sh
sudo systemctl start postgresql
```

Si estás en WSL y aparece un mensaje indicando que no se usa `systemd`, ejecuta
esta alternativa en lugar del comando anterior:

```sh
sudo service postgresql start
```

**Paso 10. Dar acceso a tu usuario de Ubuntu.**

La aplicación se conectará a PostgreSQL usando el nombre de tu usuario de Ubuntu.
Este comando crea una cuenta de base de datos con ese mismo nombre y le permite
crear las bases del proyecto; no le da permisos de superusuario.

```sh
sudo -u postgres createuser --login --createdb --no-superuser --no-createrole "$(id -un)"
```

Si no aparece un error y vuelve la línea para escribir, terminó correctamente.
Si indica que el usuario ya existe, no intentes borrarlo ni recrearlo: continúa
con la comprobación del paso siguiente. Si hay otro error, resuélvelo antes de seguir.

**Paso 11. Comprobar la conexión.**

Este comando solo consulta el nombre de la cuenta conectada; no crea ni borra datos.

```sh
psql -d postgres -c 'SELECT current_user;'
```

Debe mostrar tu usuario de Ubuntu. Si no conecta, detente: la base debe estar
disponible antes de preparar el proyecto. Si la cuenta ya existía pero no tiene
permiso para crear bases, pide que revisen sus permisos en lugar de borrarla.

Ya terminaste la preparación de Ubuntu. **Salta la sección macOS y continúa en
[Preparar el proyecto](#preparar-el-proyecto).**

Fuentes de estos pasos: [dependencias de Ruby](https://github.com/rbenv/ruby-build/wiki#ubuntudebianmint),
[instalador de mise](https://mise.jdx.dev/getting-started.html),
[PostgreSQL para Ubuntu](https://www.postgresql.org/download/linux/ubuntu/) y
[servicios en WSL](https://learn.microsoft.com/en-us/windows/wsl/tutorials/wsl-database#install-postgresql).
Si el asistente de PostgreSQL indica que tu versión de Ubuntu no está soportada,
revisa esa guía oficial antes de continuar.

### macOS

Esta ruta de instalación nueva usa Homebrew en un Mac con chip Apple Silicon
(M1 o posterior) y macOS 15 o posterior, según sus requisitos actuales. Puedes
ver esos datos en el menú Apple → **Acerca de este Mac**. Si tienes un Mac Intel
o un sistema anterior, no ejecutes estos pasos como si fueran compatibles:
el instalador actual tiene otras restricciones; consulta la
[compatibilidad oficial](https://docs.brew.sh/Installation) para preparar una alternativa.

Abre **Terminal**: puedes presionar `Command+Espacio`, escribir `Terminal` y
presionar Enter. Todos los comandos de esta sección se ejecutan en esa ventana.

**Paso 1. Instalar las herramientas de Apple.**

Se abrirá un instalador. Acepta la instalación y espera a que termine. Estas
herramientas incluyen Git, que utilizaremos para descargar el proyecto.

```sh
xcode-select --install
```

Si informa que las herramientas ya están instaladas, continúa con el paso siguiente.

**Paso 2. Instalar Homebrew.**

Homebrew permite instalar programas desde Terminal. El siguiente comando descarga
su instalador oficial; lee las indicaciones y espera a que termine.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Paso 3. Preparar Homebrew para las próximas terminales.**

En una instalación nueva con la ubicación predeterminada `/opt/homebrew`, este
comando agrega la activación a la configuración de tu usuario. Ejecútalo una sola
vez; si el instalador ya te indicó y ejecutaste este mismo paso, no lo repitas.

```sh
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
```

Si usas una instalación previa con otra ubicación, conserva la ruta indicada por
su instalador en vez de copiar esta ruta. No cambies la instalación existente.

**Paso 4. Activar Homebrew en la ventana actual.**

El paso anterior prepara ventanas futuras. Este activa la que estás utilizando:

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"
```

**Paso 5. Comprobar que Homebrew está disponible.**

```sh
brew --version
```

Debe mostrar una versión de Homebrew. Si dice `command not found`, vuelve a las
instrucciones **Next steps** del instalador antes de continuar.

**Paso 6. Instalar las bibliotecas de apoyo.**

Son los componentes que Ruby y sus complementos pueden necesitar. No tienes que
configurarlos individualmente: Homebrew se encarga de instalarlos.

```sh
brew install openssl@3 readline libyaml gmp autoconf rust vips
```

**Paso 7. Instalar PostgreSQL.**

PostgreSQL guardará las órdenes. Homebrew también prepara su espacio de datos
inicial, por lo que no necesitas ejecutar otro comando para inicializarlo.

```sh
brew install postgresql@18
```

**Paso 8. Hacer que la terminal encuentre las herramientas de PostgreSQL.**

El comando obtiene la ubicación real de Homebrew, sin asumir qué tipo de Mac usas.
Esta configuración dura mientras mantengas abierta la terminal.

```sh
export PATH="$(brew --prefix postgresql@18)/bin:$PATH"
```

**Paso 9. Encender PostgreSQL.**

Homebrew lo inicia y lo deja configurado para arrancar al iniciar sesión.

```sh
brew services start postgresql@18
```

**Paso 10. Instalar mise.**

Mise nos permitirá descargar la versión de Ruby usada por el proyecto.

```sh
curl -fsSL https://mise.run | sh
```

**Paso 11. Activar mise en esta terminal.**

Este comando es para el intérprete `zsh`, que usan las instalaciones actuales de
macOS. Tendrás que repetirlo si abres una terminal nueva.

```sh
eval "$(~/.local/bin/mise activate zsh)"
```

**Paso 12. Comprobar la conexión con PostgreSQL.**

Una instalación nueva de Homebrew normalmente permite conectar con tu usuario
del Mac. Este comando muestra el nombre de la cuenta conectada sin cambiar datos.

```sh
psql -d postgres -c 'SELECT current_user;'
```

Si muestra tu usuario, continúa en **Preparar el proyecto**. Si falla, comprueba
que PostgreSQL está encendido. No borres una instalación existente para intentar resolverlo.

Fuentes: [Homebrew](https://brew.sh/), [PostgreSQL en Homebrew](https://formulae.brew.sh/formula/postgresql@18),
[dependencias de Ruby para macOS](https://github.com/rbenv/ruby-build/wiki#macos) y
[mise](https://mise.jdx.dev/getting-started.html). Estas instrucciones de instalación
no implican que macOS o Ubuntu nativo hayan sido probados en este proyecto.

### Preparar el proyecto

Desde aquí los pasos son iguales para los tres sistemas. En Windows sigue usando
**Ubuntu**, no PowerShell. Mantén abierta la terminal donde activaste mise.

**Paso 1. Descargar el proyecto.**

Git descarga los archivos y los coloca en una carpeta llamada `niufoods-orders`
dentro de tu carpeta personal. En Windows esa carpeta estará dentro de Ubuntu.

```sh
git clone https://github.com/jmanuelbello30/niufoods-orders-bk.git ~/niufoods-orders
```

Si la carpeta ya existe, no la borres: comprueba si ya contiene este proyecto.
Si GitHub solicita acceso o muestra un error de permisos, necesitas tener acceso
al repositorio antes de continuar.

**Paso 2. Entrar a la carpeta descargada.**

Los siguientes comandos deben ejecutarse desde esta carpeta.

```sh
cd ~/niufoods-orders
```

**Paso 3. Autorizar la configuración de herramientas del proyecto.**

El archivo `mise.toml` indica que se utiliza Ruby 3.4.11. Puedes abrirlo con un
editor de texto antes de continuar. El comando permite a mise usar esa configuración.

```sh
mise trust
```

**Paso 4. Instalar Ruby.**

Mise descarga la versión
indicada por el proyecto; esta operación puede tardar varios minutos.

```sh
mise install
```

**Paso 5. Comprobar que Ruby está disponible.**

El resultado debe comenzar con `ruby 3.4.11`. Si dice que no encuentra el comando,
repite la activación de mise correspondiente a Ubuntu o macOS y vuelve a comprobar.

```sh
ruby --version
```

**Paso 6. Instalar Bundler.**

Bundler descarga y organiza las bibliotecas de Ruby. Usaremos la versión guardada
por el proyecto para que la instalación sea consistente.

```sh
gem install bundler -v 4.0.22
```

**Paso 7. Instalar las bibliotecas de la aplicación.**

Esto instala Rails y los demás componentes necesarios, con las versiones de
`Gemfile.lock`. No necesitas instalar Rails por separado. Espera a que termine
sin errores antes de seguir.

```sh
bundle install
```

**Paso 8. Comprobar que no se usará una conexión de otro proyecto.**

Si ya usabas el computador para otros proyectos, pueden haber quedado guardadas
instrucciones que apuntan a otra base. El siguiente comando muestra solo sus
nombres, nunca contraseñas ni direcciones:

```sh
ruby -e 'configured = %w[DATABASE_URL PGHOST PGPORT PGUSER PGPASSWORD].select { |name| ENV.key?(name) }; puts(configured.empty? ? "No connection overrides" : "Connection overrides: #{configured.join(", ")}")'
```

Si aparece `No connection overrides`, sigue directamente al paso 10. Si aparece
`Connection overrides`, realiza el paso 9 antes de continuar con esta guía local.

**Paso 9. Desactivar esas instrucciones solo en esta terminal, si aparecen.**

Hazlo únicamente para seguir la conexión local de esta guía. No borra bases ni
archivos y no cambia otros procesos; quita esas variables de la ventana actual.
Si necesitas conservar una conexión personalizada, detente y pide que la revisen.

```sh
unset DATABASE_URL PGHOST PGPORT PGUSER PGPASSWORD
```

**Paso 10. Revisar dónde se guardarán los datos.**

Este comando muestra la configuración de conexión de Rails sin imprimir contraseñas.
No crea bases ni modifica órdenes.

```sh
RAILS_ENV=development bin/rails runner 'puts ActiveRecord::Base.connection_db_config.configuration_hash.slice(:database, :host, :port, :username).inspect'
```

El nombre de la base debe ser `niufoods_orders_development`. En la configuración
local no se indica otro servidor: se usa PostgreSQL de tu computador.
Si aparecen otra base o un servidor que no reconoces, detente y revisa la conexión.

No es necesario crear un archivo `.env`: el proyecto no lo carga automáticamente.

**Paso 11. Crear las bases del proyecto.**

Prepara el espacio que la aplicación utilizará para guardar la información.
Si ya existen, no es necesario borrarlas.

```sh
RAILS_ENV=development bin/rails db:create
```

**Paso 12. Preparar las tablas.**

Las tablas organizan los usuarios, restaurantes, productos y órdenes dentro de la
base de datos. Este comando aplica la estructura definida por el proyecto.

```sh
RAILS_ENV=development bin/rails db:migrate
```

**Paso 13. Cargar los datos de ejemplo.**

Se agregan 3 restaurantes y 10 productos con sus precios para probar el flujo.
Este comando no envía órdenes a las tiendas. Puede repetirse si los datos siguen
coincidiendo; si encuentra un conflicto, se detiene sin sobrescribirlos.

```sh
RAILS_ENV=development bin/rails db:seed
```

**Paso 14. Crear la cuenta para iniciar sesión.**

La siguiente cuenta es ficticia y sirve para la evaluación local. Guarda el correo
y la contraseña: los ingresarás en Swagger y, si lo instalas, en Angular.

```sh
RAILS_ENV=development DEMO_USER_EMAIL=demo@example.test \
  DEMO_USER_PASSWORD='Fictional-password-123' bin/rails demo_user:provision
```

Debe aparecer `Demo user provisioned`. Si dice que el usuario ya existe, el comando
no cambia su contraseña: utiliza las credenciales con las que fue creado.
Si eliges otra contraseña, debe tener al menos 12 caracteres y como máximo 72 bytes.

## 3. Abrir el proyecto y enviar una orden

### Encender la API

**Paso 1. Usar la terminal donde preparaste el proyecto.**

Debe seguir ubicada en `~/niufoods-orders`. Si no estás seguro, entra nuevamente:

```sh
cd ~/niufoods-orders
```

**Paso 2. Iniciar Rails.**

Esto deja a la API escuchando solicitudes en el puerto 3000. Busca un mensaje
con `Listening` y `3000`. **Mantén esta terminal abierta:** mientras esté encendida
la API, esa ventana no quedará disponible para escribir otros comandos.

```sh
bin/rails server
```

### Encender la tienda simulada

**Paso 1. Abrir una segunda terminal.**

En Windows abre otra ventana de **Ubuntu**. En Ubuntu abre otra Terminal. En macOS
abre una nueva ventana de Terminal. No detengas la API de la primera ventana.

**Paso 2. Activar las herramientas en esta nueva ventana.**

En Ubuntu o Ubuntu/Windows ejecuta:

```sh
eval "$(~/.local/bin/mise activate bash)"
```

En macOS ejecuta esta alternativa:

```sh
eval "$(~/.local/bin/mise activate zsh)"
```

**Paso 3. Entrar a la carpeta del proyecto.**

```sh
cd ~/niufoods-orders
```

**Paso 4. Iniciar el receptor de órdenes.**

Este programa representa a la tienda y escucha en el puerto 4567, solo en tu
computador. Debe aparecer `Store receiver listening`. Deja también esta ventana abierta.

```sh
bundle exec ruby script/store_receiver.rb
```

### Usar Swagger desde el navegador

**Paso 1. Abrir Swagger.**

En Chrome, Firefox u otro navegador abre <http://localhost:3000/api-docs>.
 La página raíz `http://localhost:3000/` no tiene una pantalla de inicio;
usa la dirección completa de Swagger.

**Paso 2. Iniciar sesión.**

Abre `POST /api/v1/auth/login` y pulsa **Try it out**. En el cuadro de datos,
utiliza el correo y la contraseña de la cuenta que creaste:

```json
{
  "email": "demo@example.test",
  "password": "Fictional-password-123"
}
```

Pulsa **Execute**. Debajo debe aparecer un código `200`, que significa que el
inicio de sesión fue correcto, y un bloque de respuesta con `data.access_token`.

**Paso 3. Autorizar las siguientes solicitudes.**

El token es un texto que demuestra que ya iniciaste sesión. Copia el valor completo
de `access_token`, sin las comillas. Pulsa **Authorize**, pega **solo ese texto**
en el campo disponible y confirma con el botón **Authorize** del cuadro. Luego ciérralo.
No escribas la palabra `Bearer`: Swagger la agrega por ti.

Iniciar sesión no completa este paso automáticamente. El token vence a las ocho
horas; el campo `expires_at` de la respuesta indica cuándo. Si luego recibes `401`,
vuelve a iniciar sesión y reemplaza el token en **Authorize**.

**Paso 4. Crear una orden de ejemplo.**

Abre `POST /api/v1/orders`, pulsa **Try it out** y selecciona el ejemplo de retiro
simple sin total declarado. Conserva sus datos y pulsa **Execute**.

Debe aparecer `201`, que significa que se guardó una orden nueva. Busca estos campos:

- `id`: el número que identifica la orden; anótalo para comparar las pantallas.
- `total_amount`: el total calculado por la API, expresado en pesos chilenos.
- `dispatch_status`: `sent` si la tienda confirmó la recepción o `error` si falló el envío o su confirmación.

**Cada ejecución válida crea otra orden.** No pulses Execute repetidamente si
solo deseas consultar la que ya enviaste. Un `201` confirma la creación, no
garantiza por sí solo que la tienda haya recibido el pedido.

**Paso 5. Comprobar la recepción en la tienda.**

Abre otra pestaña con <http://localhost:4567/>. Verás **Tienda simulada**.
Pulsa **Actualizar** y busca el número que anotaste. La página muestra los
productos por su ID, cantidades, precios y datos recibidos, sin completar nombres
desde el catálogo. La hora mostrada es la de aceptación en la tienda, en horario
de Santiago, no la hora de creación de Rails.

La tienda conserva sus recepciones solo mientras ese programa está encendido.
Si lo reinicias, la página vuelve a quedar vacía, aunque las órdenes continúen
guardadas en la base de la API. Recibir una orden no significa prepararla ni entregarla.

**Paso 6. Consultar la orden en Angular, si deseas usar el dashboard.**

La interfaz se instala por separado: sigue el README del
[repositorio frontend](https://github.com/jmanuelbello30/niufoods-orders-ft).
Cuando esté funcionando, abre <http://localhost:4200>, inicia sesión con la cuenta
creada, pulsa **Actualizar** y abre el detalle de la orden usando el icono de ojo.

No necesitas instalar Angular para completar los cinco pasos anteriores.
Para consultar órdenes no hace falta tener la tienda encendida; para que un envío
o reintento termine en `sent`, sí debe estar disponible y confirmar la recepción.

### Apagar o volver a abrir el proyecto

Para detener la API, ve a su terminal y pulsa `Ctrl+C`. Haz lo mismo en la terminal
de la tienda. Cerrar una pestaña del navegador no detiene esos programas.

Para volver a usarlos no repitas la instalación ni crees otra vez la cuenta.
Primero enciende PostgreSQL: en Ubuntu o Ubuntu/Windows repite el **paso 9 de
Ubuntu**, incluida la alternativa `service` si corresponde. En macOS repite
los **pasos 8 y 9 de macOS**, para encontrar sus herramientas y encender el servicio.

Comprueba que está disponible con este comando en esa terminal:

```sh
pg_isready
```

Debe indicar `accepting connections`. Si no lo hace, resuelve el inicio de
PostgreSQL antes de continuar. Luego activa mise en cada terminal, entra a
`~/niufoods-orders` y repite los pasos de **Encender la API** y **Encender la tienda simulada**.

Si el navegador dice que no puede conectar, comprueba que la ventana correspondiente
siga abierta y que no haya mostrado un error al arrancar. Los mensajes
`command not found` suelen indicar que falta instalar o activar una herramienta;
no se resuelven borrando la base de datos.

### Ejemplos adicionales con comandos (opcional)

Estos ejemplos usan `curl`, un programa para enviar solicitudes desde una terminal.
Puedes omitirlos si ya probaste Swagger. Usa una **tercera terminal**, activa mise
como antes y mantén encendidas la API y la tienda. Los datos son ficticios.

**Paso 1. Obtener un token.**

La respuesta tiene el mismo contenido que el login de Swagger. El código `200`
indica que el acceso fue correcto.

```sh
curl -i http://localhost:3000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  --data '{
    "email": "demo@example.test",
    "password": "Fictional-password-123"
  }'
```

**Paso 2. Guardar el token en esta terminal.**

Reemplaza el marcador por el valor de `data.access_token` que acabas de recibir.
El marcador no es un token válido. El comando guarda el texto con el nombre
`API_TOKEN` para usarlo en los siguientes ejemplos; solo dura en esta terminal.

```sh
export API_TOKEN='<PEGAR_AQUI_DATA_ACCESS_TOKEN_DEL_LOGIN>'
```

**Paso 3. Crear una orden válida.**

Se piden dos unidades del producto 1, a 8990 CLP cada una: el total será **17980 CLP**.
`pickup` significa retiro en tienda; `delivery` significa envío a domicilio y
requiere además `delivery_address`. El ejemplo siguiente crea registros reales.

```sh
curl -i http://localhost:3000/api/v1/orders \
  -H "Authorization: Bearer $API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{
    "restaurant_id": 1,
    "order_type": "pickup",
    "customer": {
      "name": "Test Customer",
      "phone": "+56000000000"
    },
    "items": [
      { "product_id": 1, "quantity": 2 }
    ]
  }'
```

Con la tienda disponible, recibirás una respuesta como esta. El ID y la fecha
cambiarán en tu ejecución:

```json
{
  "data": {
    "id": 9001,
    "restaurant_id": 1,
    "order_type": "pickup",
    "total_amount": 17980,
    "dispatch_status": "sent",
    "created_at": "2026-10-23T12:00:00.000Z"
  }
}
```

**Paso 4. Probar el rechazo de un total incorrecto.**

Aquí se declaran 17000 CLP para los mismos productos, aunque suman 17980 CLP.
La API responde `422`, no guarda la orden ni intenta enviarla a la tienda.

```sh
curl -i http://localhost:3000/api/v1/orders \
  -H "Authorization: Bearer $API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{
    "restaurant_id": 1,
    "order_type": "pickup",
    "customer": {
      "name": "Test Customer",
      "phone": "+56000000000"
    },
    "items": [
      { "product_id": 1, "quantity": 2 }
    ],
    "client_total_amount": 17000
  }'
```

El mensaje informa ambos montos para explicar el rechazo:

```json
{
  "errors": [
    {
      "field": "client_total_amount",
      "code": "total_mismatch",
      "message": "Declared total 17000 CLP does not match calculated total 17980 CLP"
    }
  ]
}
```

`client_total_amount` es opcional: si no lo envías, la API calcula el total; si
lo envías, debe coincidir. Cuando coincide se conserva internamente, pero no se
devuelve en la respuesta de creación.

También existen estas operaciones, que requieren el token de una sesión válida:

| Operación | Para qué sirve |
| --- | --- |
| `GET /api/v1/auth/me` | Consultar qué usuario inició sesión. |
| `DELETE /api/v1/auth/logout` | Cerrar y revocar esa sesión; responde 204 sin contenido. |
| `GET /api/v1/orders` | Consultar la lista de órdenes. |
| `GET /api/v1/orders/:id` | Consultar una orden; reemplaza `:id` por su número. |
| `POST /api/v1/orders/:id/retry_dispatch` | Reintentar el envío de una orden pendiente o con error, sin enviar un cuerpo. |

El reintento responde `200` si terminó el intento, pero su `dispatch_status` puede
seguir siendo `error`. Si la orden no existe responde `404`; si ya está enviada,
responde `409` sin reenviarla.

### Crear varias órdenes con el simulador (opcional)

El simulador es un programa que envía ejemplos a la API. No reemplaza a la tienda:
debes mantener encendidas la API y la tienda para obtener envíos exitosos.

**Paso 1. Usar una terminal con `API_TOKEN` guardado.**

Obtén y guarda el token como se explica en los pasos 1 y 2 de los ejemplos con
comandos. Luego entra a la carpeta del proyecto:

```sh
cd ~/niufoods-orders
```

**Paso 2. Elegir una ejecución.**

Para usar la configuración predeterminada, ejecuta:

```sh
ruby script/simulate_orders.rb
```

Como alternativa, este comando envía 12 órdenes válidas y utiliza el número 42
para repetir la misma selección de datos de ejemplo. Elige una ejecución u otra;
no necesitas ejecutar ambas.

```sh
ORDER_COUNT=12 RANDOM_SEED=42 ruby script/simulate_orders.rb
```

En ambos casos se agregan ejemplos inválidos para comprobar rechazos: cantidad
cero, producto inexistente o repetido, envío sin dirección y total diferente.
Se usan varias tiendas, tipos de pedido, productos y cantidades del catálogo inicial.
**Cada ejecución crea nuevas órdenes**, incluso si repites `RANDOM_SEED`.

Al terminar verás un resumen. El código de salida `0` significa que los ejemplos
obtuvieron el resultado esperado; puede haber órdenes creadas con envío fallido.
`1` indica un resultado inesperado y `2`, una configuración inválida, como no tener
token. Un error `401` o `403` detiene el resto de los envíos. El programa no inicia
sesión por ti. `API_BASE_URL` permite cambiar la dirección de la API; por defecto
usa `http://localhost:3000`.

### Ver qué ocurre cuando falla o se demora la tienda (opcional)

**Paso 1. Detener la tienda actual.**

En su terminal pulsa `Ctrl+C`. La API puede seguir funcionando en la otra ventana.

**Paso 2. Elegir un modo y volver a encender la tienda.**

Para simular que la tienda rechaza los envíos sin aceptarlos, ejecuta:

```sh
STORE_MODE=error bundle exec ruby script/store_receiver.rb
```

Como alternativa, para simular que tarda seis segundos en aceptar, ejecuta:

```sh
STORE_MODE=delay STORE_DELAY_SECONDS=6 bundle exec ruby script/store_receiver.rb
```

No ejecutes ambos a la vez. Si quieres cambiar de modo, detén primero el proceso
con `Ctrl+C`. Puedes volver al modo normal con el comando original de inicio.

**Paso 3. Enviar una nueva orden válida desde Swagger.**

En modo error se guardará en Rails, pero el envío quedará en `error` y no aparecerá
como aceptada en la tienda. En modo demora, Rails puede dejar de esperar antes
de que la tienda termine: al actualizar la vista más tarde podrías verla aceptada,
aunque Rails muestre `error`. Eso no significa que se haya preparado ni entregado.

Mantén el puerto predeterminado 4567 para seguir esta guía. `STORE_PORT` permite
cambiarlo, pero no cambia automáticamente las direcciones guardadas por los seeds.

## 4. Decisiones técnicas relevantes

**1.Rails y PostgreSQL tienen responsabilidades distintas.** Rails recibe y valida
las solicitudes. PostgreSQL guarda la información. La API y Angular están separados
para que distintas interfaces puedan usar las mismas reglas de negocio.

**2. Guardar la orden ocurre antes de enviarla.** La orden y sus ítems se guardan como
una sola operación: si algo falla durante ese guardado, no queda una orden parcial.
Después de confirmarlo, Rails llama al servicio de despacho. El código separa esa
creación (`Orders::Create`) del envío (`Orders::Dispatch`) para mantener claras
ambas responsabilidades y los controladores enfocados en coordinar las solicitudes.

**3. Los precios quedan asociados a la orden.** Cada ítem conserva el precio utilizado
al comprar; un cambio posterior del catálogo no cambia ese precio histórico.
Los montos se manejan como pesos chilenos enteros, sin centavos. Si el canal informa
un total, Rails lo compara con el que calcula y rechaza las diferencias.

**4. El envío es inmediato y se espera su resultado.** Se eligió un despacho síncrono
para mantener sencillo el alcance: la solicitud espera mientras se intenta enviar.
La conexión tiene un límite de 2 segundos; lectura y escritura, de 5 segundos cada
una. Son límites por operación, no una duración máxima total. No hay reintentos
automáticos ni seguimiento de redirecciones; el reintento es manual.

**5. Una respuesta de la tienda debe confirmar la orden correcta.** No basta con
recibir HTTP 200: se valida que el contenido confirme la aceptación y que los
identificadores coincidan. El receptor reconoce duplicados por tienda y número de
orden, sin crear otra entrada ni cambiar sus datos u hora originales. Ese registro
vive solo en memoria y se borra al reiniciar el receptor.

**6. Swagger facilita la evaluación.** Permite iniciar sesión y crear órdenes desde
el navegador. Está disponible solo en development y test. La especificación
[OpenAPI](openapi/v1/openapi.yaml) documenta esas dos operaciones y también se
puede descargar en <http://localhost:3000/api-docs/v1/openapi.yaml>.

**7. Hay límites intencionales.** No se garantiza entrega exactamente una vez ni se
coordinan globalmente los envíos simultáneos. Todos los usuarios autenticados
comparten acceso a las órdenes; no hay roles ni separación por restaurante.
El listado no tiene paginación. El límite de login es de 10 intentos por minuto
e IP, aplicado por proceso, no globalmente. Fuera del entorno local se requiere HTTPS.

**8. Pruebas automatizadas con Minitest.** 
 Cubren el cálculo de totales, las validaciones, la autenticación y el despacho de órdenes, incluidos los escenarios de error. Las respuestas de la tienda se simulan durante las pruebas, sin enviar órdenes reales.

Los contratos completos, el catálogo y las limitaciones detalladas se conservan
en [docs/alcance.md](docs/alcance.md).
