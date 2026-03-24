export default function HomePage() {
  return (
    <div className="flex flex-1 items-center justify-center">
      <div className="text-center">
        <img
          src="/logo.jpg"
          alt="CYFR"
          className="mx-auto h-16 w-16 rounded-2xl object-cover"
        />
        <h1 className="mt-4 text-2xl font-semibold text-text-primary">
          Welcome to CYFR
        </h1>
        <p className="mt-2 text-sm text-text-secondary">
          Your AI-powered workspace
        </p>
      </div>
    </div>
  );
}
